// Prove routing by cache id for the routing-ws pattern (streaming, unidirectional).
//
// "alpha" is owned by instance 0 (aeroncache-ws-0 + aeroncache-http-0), "beta" by instance 1. The WS
// *subscribe* route carries the cache id in the path (/api/ws/v1/cache/<id>) and is what we route; the
// bidi endpoint carries the id in the frame, so it is not path-routable. Writes go through the
// per-instance http writer, routed by the same id. Proof is by LIVE UPDATE (subscribe, then write, then
// observe), so it does not depend on snapshot-on-connect behaviour:
//   1. Routed round-trip — subscribe to each cache THROUGH the ingress, write it via the ingress http
//      route, and see the value pushed to that subscription.
//   2. Landing + isolation — subscribe DIRECTLY to both ws gateways for "alpha", write a fresh value
//      via the ingress, and assert only the owner (ws-0) receives it, never ws-1. That rules out
//      round-robin: the ingress routed by the cache id.
//
// Run by `make verify` via common/smoke.sh (SMOKE_MODE=command). This script owns its port-forwards
// (ingress controller + both ws gateways). Node 22+ (global WebSocket + fetch).
import { spawn } from 'node:child_process';

const NAMESPACE = process.env.NAMESPACE || 'aeroncache-patterns';
const ING_PORT = 18080, WS0_PORT = 17071, WS1_PORT = 17072;
const ING_HTTP = `http://localhost:${ING_PORT}`;
const sub_url = (host, port, id) => `ws://localhost:${port}/api/ws/v1/cache/${id}`;

const fail = (m) => { console.error(`ROUTING VERIFY FAILED: ${m}`); process.exit(1); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- port-forwards ----------------------------------------------------------
const forwards = [];
function portForward(ns, svc, mapping) {
  const p = spawn('kubectl', ['port-forward', '-n', ns, svc, mapping], { stdio: 'ignore' });
  forwards.push(p);
}
function cleanup() { for (const p of forwards) { try { p.kill(); } catch {} } }
process.on('exit', cleanup);
process.on('SIGINT', () => { cleanup(); process.exit(1); });

// --- a subscription that records every frame it receives --------------------
function subscribe(url, attempts = 12) {
  return new Promise((resolve, reject) => {
    let n = 0;
    const open = () => {
      const ws = new WebSocket(url);
      const frames = [];
      ws.addEventListener('message', (e) => frames.push(typeof e.data === 'string' ? e.data : String(e.data)));
      ws.addEventListener('open', () => resolve({ ws, frames, url }), { once: true });
      ws.addEventListener('error', () => {
        if (++n >= attempts) reject(new Error(`could not connect ${url} after ${attempts} tries`));
        else setTimeout(open, 1000);
      }, { once: true });
    };
    open();
  });
}
// Wait until some recorded frame contains needle (returns true), or timeout (returns false).
async function sawWithin(sub, needle, ms) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (sub.frames.some((f) => f.includes(needle))) return true;
    await sleep(200);
  }
  return false;
}

async function createCache(id) {
  const r = await fetch(`${ING_HTTP}/api/v1/cache/${id}`, { method: 'PUT' });
  if (!r.ok && r.status !== 409) fail(`create '${id}' via ingress -> HTTP ${r.status}`);
}
async function putValue(id, value) {
  const r = await fetch(`${ING_HTTP}/api/v1/cache/${id}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ key: 'testKey', value }),
  });
  if (!r.ok) fail(`put '${id}'='${value}' via ingress -> HTTP ${r.status}`);
}

const main = async () => {
  console.log('==> Port-forwarding the ingress controller and both ws gateways');
  portForward('ingress-nginx', 'svc/ingress-nginx-controller', `${ING_PORT}:80`);
  portForward(NAMESPACE, 'svc/aeroncache-ws-0', `${WS0_PORT}:7071`);
  portForward(NAMESPACE, 'svc/aeroncache-ws-1', `${WS1_PORT}:7071`);
  await sleep(4000);

  // Caches must exist before we subscribe to them. Create via the routed http writers.
  // (retry the first write a few times while the ingress/backends finish coming up)
  for (let i = 0; i < 10; i++) {
    try { await createCache('alpha'); await createCache('beta'); break; }
    catch (e) { if (i === 9) throw e; await sleep(3000); }
  }

  // --- 1. Routed round-trip through the ingress -----------------------------
  console.log('==> [1] Subscribe to alpha and beta THROUGH the ingress, then write each');
  const ingAlpha = await subscribe(sub_url('ingress', ING_PORT, 'alpha'));
  const ingBeta = await subscribe(sub_url('ingress', ING_PORT, 'beta'));
  await sleep(500);
  await putValue('alpha', 'alpha-value');
  await putValue('beta', 'beta-value');
  if (!(await sawWithin(ingAlpha, 'alpha-value', 12000))) fail("routed ws subscribe for 'alpha' never received alpha-value");
  if (!(await sawWithin(ingBeta, 'beta-value', 12000))) fail("routed ws subscribe for 'beta' never received beta-value");
  console.log('    both routed subscriptions received their value');
  ingAlpha.ws.close(); ingBeta.ws.close();

  // --- 2. Landing + isolation (live, proves routing by cache id) ------------
  console.log('==> [2] Subscribe DIRECTLY to ws-0 and ws-1 for alpha, then write a fresh value');
  const owner = await subscribe(sub_url('ws-0', WS0_PORT, 'alpha'));     // instance 0 owns alpha
  const other = await subscribe(sub_url('ws-1', WS1_PORT, 'alpha'));     // instance 1 must never see it
  await sleep(500);
  await putValue('alpha', 'alpha-live');
  if (!(await sawWithin(owner, 'alpha-live', 12000))) fail('landing: owner ws-0 did not receive the alpha update');
  console.log('    owner ws-0 received the update');
  if (await sawWithin(other, 'alpha-live', 4000)) fail('ISOLATION BROKEN: ws-1 received an alpha update — routing is not by cache id');
  console.log('    non-owner ws-1 did NOT receive it (isolated)');
  owner.ws.close(); other.ws.close();

  console.log('==> ROUTING VERIFY PASSED (alpha->instance 0, beta->instance 1, isolated)');
  process.exit(0);
};

main().catch((e) => fail(e?.message || String(e)));
