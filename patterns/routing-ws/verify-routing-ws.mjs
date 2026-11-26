// Prove routing by cache id for the routing-ws pattern (streaming, unidirectional).
//
// "alpha" is owned by instance 0 (aeroncache-ws-0 + aeroncache-http-0), "beta" by instance 1. The WS
// *subscribe* route carries the cache id in the path (/api/ws/v1/cache/<id>) and is what we route; the
// bidi endpoint carries the id in the frame, so it is not path-routable. Writes go through the
// per-instance http writer, routed by the same id.
//
// Proof is by SNAPSHOT-ON-CONNECT (write first, then subscribe and read the snapshot) — the same model
// the routing-sse verify uses. (A post-subscribe live update is delivered promptly by an ephemeral
// backend but not reliably by a freshly-established subscription against a RAFT cluster, so we don't
// depend on it.) Asserts:
//   1. Routed round-trip — write each cache via the ingress, then subscribe to it THROUGH the ingress
//      and see the value in the snapshot.
//   2. Landing + isolation — subscribe DIRECTLY to each ws gateway: "alpha" is in ws-0's snapshot, and
//      NOT in ws-1's (that backend never received it). That rules out round-robin.
//
// Run by `make verify` via common/smoke.sh (SMOKE_MODE=command). This script owns its port-forwards
// (ingress controller + both ws gateways). Node 22+ (global WebSocket + fetch).
import { spawn } from 'node:child_process';

const NAMESPACE = process.env.NAMESPACE || 'aeroncache-patterns';
const ING_PORT = 18080, WS0_PORT = 17071, WS1_PORT = 17072;
const ING_HTTP = `http://localhost:${ING_PORT}`;
const sub_url = (port, id) => `ws://localhost:${port}/api/ws/v1/cache/${id}`;

const fail = (m) => { console.error(`ROUTING VERIFY FAILED: ${m}`); process.exit(1); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- port-forwards ----------------------------------------------------------
const forwards = [];
function portForward(ns, svc, mapping) {
  forwards.push(spawn('kubectl', ['port-forward', '-n', ns, svc, mapping], { stdio: 'ignore' }));
}
function cleanup() { for (const p of forwards) { try { p.kill(); } catch {} } }
process.on('exit', cleanup);
process.on('SIGINT', () => { cleanup(); process.exit(1); });

// Open a subscription and record every frame. Returns {ws, frames} on open; rejects after N tries.
function subscribe(url, attempts = 15) {
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
// Like subscribe, but returns null instead of throwing if it never connects (used for the isolation
// probe, where the target cache may not exist on that backend at all).
async function subscribeMaybe(url) { try { return await subscribe(url, 6); } catch { return null; } }

// Poll a subscription's frames for a substring until found (true) or timeout (false).
async function sawWithin(sub, needle, ms) {
  if (!sub) return false;
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (sub.frames.some((f) => f.includes(needle))) return true;
    await sleep(200);
  }
  return false;
}

async function createCache(id) {
  const r = await fetch(`${ING_HTTP}/api/v1/cache/${id}`, { method: 'PUT' });
  if (!r.ok && r.status !== 409) throw new Error(`create '${id}' via ingress -> HTTP ${r.status}`);
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

  // Write both caches FIRST (routed to the per-instance http writers), with a retry while the
  // ingress/backends finish coming up. Then a settle so a clustered backend has committed the write
  // before we read the snapshot.
  console.log('==> Write alpha and beta THROUGH the ingress (http write route)');
  for (let i = 0; i < 10; i++) {
    try { await createCache('alpha'); await createCache('beta'); break; }
    catch (e) { if (i === 9) throw e; await sleep(3000); }
  }
  await putValue('alpha', 'alpha-value');
  await putValue('beta', 'beta-value');
  await sleep(3000);

  // --- 1. Routed round-trip: read each back over a subscription via the ingress -----------------
  console.log('==> [1] Subscribe to alpha and beta THROUGH the ingress and read the snapshot');
  const ingAlpha = await subscribe(sub_url(ING_PORT, 'alpha'));
  if (!(await sawWithin(ingAlpha, 'alpha-value', 15000))) fail("routed ws subscribe for 'alpha' never streamed alpha-value");
  const ingBeta = await subscribe(sub_url(ING_PORT, 'beta'));
  if (!(await sawWithin(ingBeta, 'beta-value', 15000))) fail("routed ws subscribe for 'beta' never streamed beta-value");
  console.log('    both routed subscriptions received their value');
  ingAlpha.ws.close(); ingBeta.ws.close();

  // --- 2. Landing + isolation (direct subscriptions) -------------------------------------------
  console.log('==> [2] Subscribe DIRECTLY: alpha is on ws-0, and must be absent on ws-1');
  const owner = await subscribe(sub_url(WS0_PORT, 'alpha'));
  if (!(await sawWithin(owner, 'alpha-value', 15000))) fail('landing: alpha not found on its owner ws-0');
  console.log('    owner ws-0 has alpha');
  const other = await subscribeMaybe(sub_url(WS1_PORT, 'alpha'));
  if (await sawWithin(other, 'alpha-value', 6000)) fail('ISOLATION BROKEN: alpha is present on ws-1 — routing is not by cache id');
  console.log('    non-owner ws-1 does NOT have alpha (isolated)');
  owner.ws.close(); if (other) other.ws.close();

  console.log('==> ROUTING VERIFY PASSED (alpha->instance 0, beta->instance 1, isolated)');
  process.exit(0);
};

main().catch((e) => fail(e?.message || String(e)));
