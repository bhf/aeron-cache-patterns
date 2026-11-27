// Prove HASH routing by cache id for the routing-hash-ws pattern (streaming, unidirectional).
//
// N shards sit behind one Ingress whose server-snippet computes shard = crc32(cacheId) % N. The WS
// *subscribe* route (/api/ws/v1/cache/<id>) hashes to the per-shard ws gateway; writes hash to the
// per-shard http writer — the SAME shard, so a ws gateway on shard s only ever sees caches on backend
// s. Over a set of cache ids chosen to span several shards this asserts:
//   1. Routed round-trip (WS) — subscribe to each id THROUGH the ingress, write it via the ingress,
//      and see the value pushed to that routed subscription. The subscribe reached the owning ws
//      gateway.
//   2. Deterministic sharding — reading each id DIRECTLY from the N http writers finds it on EXACTLY
//      ONE, and (if python3/Node crc32 is available) that one is crc32(id) % N. Since each ws gateway
//      reads only its own backend, (1)+(2) prove the subscribe and the write hashed to the same shard.
//   3. Non-degenerate — the id set lands on at least two distinct shards.
//
// (Read isolation is checked over HTTP, not a second WS subscription: a direct WS subscription's
// snapshot/live delivery differs between ephemeral and clustered backends, so a WS-based probe is
// flaky; the backend-level HTTP check is deterministic on both — same choice as routing-ws.)
//
// Run by `make verify` via common/smoke.sh (SMOKE_MODE=command). This script owns its port-forwards
// (ingress controller + every http writer). Node 22+ (global WebSocket + fetch).
import { spawn } from 'node:child_process';

const NAMESPACE = process.env.NAMESPACE || 'aeroncache-patterns';
const SHARDS = parseInt(process.env.SHARDS || '3', 10);
const ING_PORT = 18080, HTTP_BASE = 17070;
const ING = `http://localhost:${ING_PORT}`;
const httpUrl = (shard) => `http://localhost:${HTTP_BASE + shard}`;
const sub_url = (id) => `ws://localhost:${ING_PORT}/api/ws/v1/cache/${id}`;

const IDS = ['users', 'pricing', 'alpha', 'beta', 'orders', 'inventory'];

const fail = (m) => { console.error(`HASH ROUTING VERIFY FAILED: ${m}`); process.exit(1); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Independent reference hash (Node 22.2+ exposes zlib.crc32); null if unavailable -> cross-check skipped.
let crc32 = null;
try { ({ crc32 } = await import('node:zlib')); if (typeof crc32 !== 'function') crc32 = null; } catch { crc32 = null; }
const expectedShard = (id) => (crc32 ? crc32(id) % SHARDS : null);

// --- port-forwards ----------------------------------------------------------
const forwards = [];
function portForward(ns, svc, mapping) {
  forwards.push(spawn('kubectl', ['port-forward', '-n', ns, svc, mapping], { stdio: 'ignore' }));
}
function cleanup() { for (const p of forwards) { try { p.kill(); } catch {} } }
process.on('exit', cleanup);
process.on('SIGINT', () => { cleanup(); process.exit(1); });

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
  // 400/409 = the cache already exists (a re-run), which is fine; anything else transient is handled
  // by the retry loop around the create pass.
  if (!r.ok && r.status !== 409 && r.status !== 400) throw new Error(`create '${id}' via ${base} -> HTTP ${r.status}`);
}
async function putValue(base, id, value) {
  const r = await fetch(`${base}/api/v1/cache/${id}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ key: 'testKey', value }),
  });
  if (!r.ok) fail(`put '${id}'='${value}' via ${base} -> HTTP ${r.status}`);
}
async function getValue(base, id) { // '' on error/404
  try { const r = await fetch(`${base}/api/v1/cache/${id}/testKey`); return r.ok ? await r.text() : ''; }
  catch { return ''; }
}

const main = async () => {
  console.log(`==> Port-forwarding the ingress controller and all ${SHARDS} http writers`);
  portForward('ingress-nginx', 'svc/ingress-nginx-controller', `${ING_PORT}:80`);
  for (let s = 0; s < SHARDS; s++) portForward(NAMESPACE, `svc/aeroncache-http-${s}`, `${HTTP_BASE + s}:7070`);
  await sleep(5000);

  // Caches must exist before we subscribe. Create via the routed http writers, retrying patiently
  // while the port-forwards come up and the controller settles after its post-allow-snippets restart
  // (a reload can drop connections for a while -> "fetch failed"). createCache tolerates 400/409, so
  // re-creating an id on a retry is harmless.
  for (let i = 0; i < 30; i++) {
    try { for (const id of IDS) await createCache(ING, id); break; }
    catch (e) { if (i === 29) throw e; await sleep(3000); }
  }

  const usedShards = new Set();
  console.log(`==> Subscribing + writing ${IDS.length} ids through the ingress and checking each one's shard`);
  for (const id of IDS) {
    const val = `val-${id}`;

    // [1] routed round-trip over WS: subscribe via ingress, then write via ingress
    const sub = await subscribe(sub_url(id));
    await sleep(1200);
    await putValue(ING, id, val);
    if (!(await sawWithin(sub, val, 15000))) fail(`routed ws subscribe for '${id}' never received ${val}`);
    sub.ws.close();

    // [2] deterministic sharding: present on exactly one backend (read each http writer directly)
    const owners = [];
    for (let s = 0; s < SHARDS; s++) if ((await getValue(httpUrl(s), id)).includes(val)) owners.push(s);
    if (owners.length !== 1) fail(`'${id}' found on ${owners.length} backends (${owners.join(',') || 'none'}) — expected exactly one`);
    const shard = owners[0];

    // optional independent hash cross-check
    const exp = expectedShard(id);
    if (exp !== null) {
      if (shard !== exp) fail(`'${id}' lands on shard ${shard} but crc32('${id}') % ${SHARDS} = ${exp}`);
      console.log(`    ${id} -> shard ${shard} (crc32 % ${SHARDS} = ${exp}) ✓`);
    } else {
      console.log(`    ${id} -> shard ${shard} ✓`);
    }
    usedShards.add(shard);
  }

  // [3] non-degenerate
  if (SHARDS > 1 && usedShards.size < 2) fail(`all ${IDS.length} ids landed on one shard — that is not hash distribution`);
  console.log(`==> ${IDS.length} ids spread across ${usedShards.size} distinct shard(s): ${[...usedShards].sort().join(' ')}`);

  console.log(`==> HASH ROUTING VERIFY PASSED (deterministic crc32 % ${SHARDS} sharding over WS, one owner per id)`);
  process.exit(0);
};

main().catch((e) => fail(e?.message || String(e)));
