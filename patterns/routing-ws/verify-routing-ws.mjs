// Prove routing by cache id for the routing-ws pattern (streaming, unidirectional).
//
// "alpha" is owned by instance 0 (aeroncache-ws-0 + aeroncache-http-0), "beta" by instance 1. The WS
// *subscribe* route carries the cache id in the path (/api/ws/v1/cache/<id>) and is what we route; the
// bidi endpoint carries the id in the frame, so it is not path-routable. Writes go through the
// per-instance http writer, routed by the same id.
//
// Asserts:
//   1. Routed round-trip (WS) — subscribe to each cache THROUGH the ingress, write it via the ingress
//      http route, and see the value pushed to that routed subscription. This proves the WS subscribe
//      is routed by cache id to the owning gateway.
//   2. Isolation (HTTP) — read each cache DIRECTLY from both http writers: it is present only on its
//      owner and absent on the other backend. Since each ws gateway reads from its own backend, a cache
//      that never reached a backend cannot be served by that backend's ws gateway either — so this is
//      the same isolation the ws layer has, checked over the deterministic REST path (as routing-http
//      does). Together with (1) it rules out round-robin.
//
// (Read isolation is checked over HTTP rather than a second WS subscription on purpose: a direct WS
// subscription's snapshot/live-update delivery differs between ephemeral and clustered backends, so a
// WS-based isolation probe is flaky; the backend-level HTTP check is deterministic on both.)
//
// Run by `make verify` via common/smoke.sh (SMOKE_MODE=command). This script owns its port-forwards
// (ingress controller + both http writers). Node 22+ (global WebSocket + fetch).
import { spawn } from 'node:child_process';

const NAMESPACE = process.env.NAMESPACE || 'aeroncache-patterns';
const ING_PORT = 18080, HTTP0_PORT = 17070, HTTP1_PORT = 17071;
const ING = `http://localhost:${ING_PORT}`;
const HTTP0 = `http://localhost:${HTTP0_PORT}`;
const HTTP1 = `http://localhost:${HTTP1_PORT}`;
const sub_url = (id) => `ws://localhost:${ING_PORT}/api/ws/v1/cache/${id}`;

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

// Open a WS subscription and record every frame. Resolves on open; rejects after N connect attempts.
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
async function sawWithin(sub, needle, ms) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (sub.frames.some((f) => f.includes(needle))) return true;
    await sleep(200);
  }
  return false;
}

async function createCache(base, id) {
  const r = await fetch(`${base}/api/v1/cache/${id}`, { method: 'PUT' });
  if (!r.ok && r.status !== 409) throw new Error(`create '${id}' via ${base} -> HTTP ${r.status}`);
}
async function putValue(base, id, value) {
  const r = await fetch(`${base}/api/v1/cache/${id}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ key: 'testKey', value }),
  });
  if (!r.ok) fail(`put '${id}'='${value}' via ${base} -> HTTP ${r.status}`);
}
async function getValue(base, id) { // returns body text ('' on error/404)
  try { const r = await fetch(`${base}/api/v1/cache/${id}/testKey`); return r.ok ? await r.text() : ''; }
  catch { return ''; }
}

const main = async () => {
  console.log('==> Port-forwarding the ingress controller and both http writers');
  portForward('ingress-nginx', 'svc/ingress-nginx-controller', `${ING_PORT}:80`);
  portForward(NAMESPACE, 'svc/aeroncache-http-0', `${HTTP0_PORT}:7070`);
  portForward(NAMESPACE, 'svc/aeroncache-http-1', `${HTTP1_PORT}:7070`);
  await sleep(4000);

  // Caches must exist before we subscribe. Create via the routed http writers (retry while the
  // ingress/backends finish coming up).
  for (let i = 0; i < 10; i++) {
    try { await createCache(ING, 'alpha'); await createCache(ING, 'beta'); break; }
    catch (e) { if (i === 9) throw e; await sleep(3000); }
  }

  // --- 1. Routed round-trip over WS (subscribe via ingress, then write via ingress) -------------
  console.log('==> [1] Subscribe to alpha and beta THROUGH the ingress, then write each');
  const ingAlpha = await subscribe(sub_url('alpha'));
  const ingBeta = await subscribe(sub_url('beta'));
  await sleep(1500);
  await putValue(ING, 'alpha', 'alpha-value');
  await putValue(ING, 'beta', 'beta-value');
  if (!(await sawWithin(ingAlpha, 'alpha-value', 15000))) fail("routed ws subscribe for 'alpha' never received alpha-value");
  if (!(await sawWithin(ingBeta, 'beta-value', 15000))) fail("routed ws subscribe for 'beta' never received beta-value");
  console.log('    both routed subscriptions received their value');
  ingAlpha.ws.close(); ingBeta.ws.close();

  // --- 2. Isolation at the backend (direct HTTP reads on each writer) ---------------------------
  console.log('==> [2] alpha lands only on instance 0, beta only on instance 1 (direct reads)');
  if (!(await getValue(HTTP0, 'alpha')).includes('alpha-value')) fail('alpha not found on its owner http-0');
  if (!(await getValue(HTTP1, 'beta')).includes('beta-value')) fail('beta not found on its owner http-1');
  if ((await getValue(HTTP1, 'alpha')).includes('alpha-value')) fail('ISOLATION BROKEN: alpha present on instance 1 — routing is not by cache id');
  if ((await getValue(HTTP0, 'beta')).includes('beta-value')) fail('ISOLATION BROKEN: beta present on instance 0 — routing is not by cache id');
  console.log('    each cache is present only on its owner (isolated)');

  console.log('==> ROUTING VERIFY PASSED (alpha->instance 0, beta->instance 1, isolated)');
  process.exit(0);
};

main().catch((e) => fail(e?.message || String(e)));
