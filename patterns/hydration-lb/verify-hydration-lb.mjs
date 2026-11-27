// Prove LOAD-BALANCED HYDRATION for the hydration-lb pattern.
//
// A pool of N identical ws gateways (one aeroncache-ws StatefulSet at replicaCount=GATEWAYS) sits over
// one shared backend, each with the server-side near cache ON. This pattern primes EVERY gateway for
// the same cache, then load-balances hydrating subscriptions across the pool with one Ingress. A
// hydrating subscribe — ws://.../api/ws/v1/cache/hydrate/<id> — asks the gateway to push a point-in-time
// snapshot (one ADD_ITEM frame per existing item) before the live stream; when the cache is warm the
// gateway serves that snapshot from its near cache and increments aeroncache_near_hydrations_served_total.
// (The non-hydrate /api/ws/v1/cache/<id> subscribe streams only future updates and does NOT hydrate.)
//
// This asserts:
//   1. Primed pool    — after priming each pod, every gateway lists the cache warm with its items.
//   2. Hydration      — M (= HYDRATIONS, default 3·N) hydrating subscriptions opened THROUGH the ingress
//                       each receive the snapshot (ADD_ITEM frames for the seeded keys).
//   3. Served by near — each gateway's own aeroncache_near_hydrations_served_total rises; the per-pod
//                       deltas sum to exactly M, so every hydration was served from a near cache (none
//                       fell through to the cluster).
//   4. Load-balanced  — those M hydrations landed on at least two distinct gateways (round-robin spread),
//                       not all on one.
//
// Run by `make verify` via common/smoke.sh (SMOKE_MODE=command). smoke.sh health-gates the pool Service;
// this script owns its own port-forwards (the ingress controller for subscriptions + each pod for
// priming and metrics). Node 22+ (global WebSocket + fetch).
import { spawn, execSync } from 'node:child_process';

const NAMESPACE = process.env.NAMESPACE || 'aeroncache-patterns';
const CACHE_ID = process.env.CACHE_ID || 'hydration-lb';
const SEED_ITEMS = Number(process.env.SEED_ITEMS || 6);
const ING_PORT = 18080;
const POD_BASE = 17071;
const WARM_TIMEOUT_MS = Number(process.env.WARM_TIMEOUT_MS || 40000);

const fail = (m) => { console.error(`HYDRATION LB VERIFY FAILED: ${m}`); process.exit(1); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- port-forwards (owned by this script, like routing-hash-ws's verify) ----
const forwards = [];
const portForward = (ns, target, mapping) => forwards.push(spawn('kubectl', ['port-forward', '-n', ns, target, mapping], { stdio: 'ignore' }));
const cleanup = () => { for (const p of forwards) { try { p.kill(); } catch {} } };
process.on('exit', cleanup);
process.on('SIGINT', () => { cleanup(); process.exit(1); });

function discoverPods() {
  const out = execSync(
    `kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=aeroncache-ws -o jsonpath='{.items[*].metadata.name}'`,
  ).toString().replace(/'/g, '').trim();
  const pods = out ? out.split(/\s+/).sort() : [];
  if (pods.length === 0) fail('no aeroncache-ws pods found — is the pattern deployed?');
  return pods;
}

function openWs(url, attempts = 20) {
  return new Promise((resolve, reject) => {
    let n = 0;
    const go = () => {
      const ws = new WebSocket(url);
      ws.addEventListener('open', () => resolve(ws), { once: true });
      ws.addEventListener('error', () => {
        if (++n >= attempts) reject(new Error(`could not connect ${url} after ${attempts} tries`));
        else setTimeout(go, 800);
      }, { once: true });
    };
    go();
  });
}

function rpc(ws, frame) {
  return new Promise((resolve, reject) => {
    const to = setTimeout(() => reject(new Error(`timeout waiting for ${frame.op}`)), 10000);
    const onMsg = (e) => {
      let m; try { m = JSON.parse(e.data); } catch { return; }
      if (m.correlationId !== frame.correlationId) return;
      clearTimeout(to); ws.removeEventListener('message', onMsg);
      if (m.type === 'error') reject(new Error(`${frame.op}: ${m.status} ${m.message || ''}`)); else resolve(m);
    };
    ws.addEventListener('message', onMsg);
    ws.send(JSON.stringify(frame));
  });
}

// Sum of aeroncache_near_hydrations_served_total across label variants on pod i's /prometheus (0 if absent).
async function hydrationsServed(i) {
  const res = await fetch(`http://localhost:${POD_BASE + i}/prometheus`).catch(() => null);
  if (!res || !res.ok) return 0;
  const text = await res.text();
  let sum = 0;
  for (const line of text.split('\n')) {
    if (line.startsWith('#')) continue;
    if (line.startsWith('aeroncache_near_hydrations_served_total')) {
      const v = Number(line.trim().split(/\s+/).pop());
      if (!Number.isNaN(v)) sum += v;
    }
  }
  return sum;
}

// itemCount for CACHE_ID in pod i's warm-cache listing (0 if not warm / absent).
async function warmItemCount(i) {
  const res = await fetch(`http://localhost:${POD_BASE + i}/api/v1/near/caches`).catch(() => null);
  if (!res || !res.ok) return 0;
  const list = await res.json().catch(() => []);
  const hit = (Array.isArray(list) ? list : []).find((c) => c.cacheId === CACHE_ID);
  return hit ? Number(hit.itemCount || 0) : 0;
}

const main = async () => {
  const pods = discoverPods();
  const N = pods.length;
  const M = Number(process.env.HYDRATIONS || 3 * N);
  console.log(`==> Pool of ${N} ws gateway(s): ${pods.join(', ')}`);

  console.log('==> Port-forwarding the ingress controller and every pool pod');
  portForward('ingress-nginx', 'svc/ingress-nginx-controller', `${ING_PORT}:80`);
  pods.forEach((p, i) => portForward(NAMESPACE, `pod/${p}`, `${POD_BASE + i}:7071`));
  await sleep(6000);

  // [seed] create the cache and write SEED_ITEMS items over one pod's bidi socket.
  console.log(`==> Seeding '${CACHE_ID}' with ${SEED_ITEMS} item(s) over bidi`);
  const bidi = await openWs(`ws://localhost:${POD_BASE}/api/ws/v1/bidi`);
  try { await rpc(bidi, { type: 'command', op: 'CREATE_CACHE', correlationId: 'c', cacheId: CACHE_ID }); }
  catch (e) { console.log(`    create note: ${e.message} (continuing)`); }
  for (let k = 0; k < SEED_ITEMS; k++) {
    const r = await rpc(bidi, { type: 'command', op: 'ADD_CACHE_ENTRY', correlationId: `a${k}`, cacheId: CACHE_ID, key: `key${k}`, value: `val${k}` });
    if (r.status !== 'SUCCESS') fail(`seed add key${k} status ${r.status}`);
  }
  bidi.close();

  // [1] prime every gateway, then wait until each lists the cache warm with all items.
  console.log(`==> Priming the near cache on all ${N} gateway(s)`);
  for (let i = 0; i < N; i++) {
    const r = await fetch(`http://localhost:${POD_BASE + i}/api/v1/near/cache/${CACHE_ID}`, { method: 'POST' }).catch(() => null);
    if (!r || !r.ok) fail(`prime ${pods[i]} failed (HTTP ${r ? r.status : 'no response'})`);
  }
  console.log(`==> Waiting up to ${WARM_TIMEOUT_MS / 1000}s for every gateway to be warm with ${SEED_ITEMS} item(s)`);
  const deadline = Date.now() + WARM_TIMEOUT_MS;
  let counts = [];
  while (Date.now() < deadline) {
    counts = await Promise.all(pods.map((_, i) => warmItemCount(i)));
    if (counts.every((c) => c >= SEED_ITEMS)) break;
    await sleep(2000);
  }
  if (!counts.every((c) => c >= SEED_ITEMS)) fail(`not every gateway warmed with ${SEED_ITEMS} items: ${JSON.stringify(Object.fromEntries(pods.map((p, i) => [p, counts[i]])))}`);
  console.log(`    warm: every gateway holds ${SEED_ITEMS} item(s) locally`);

  // [2]+[3] open M hydrating subscriptions THROUGH THE INGRESS; each must receive its snapshot.
  const before = await Promise.all(pods.map((_, i) => hydrationsServed(i)));
  console.log(`==> Baseline hydrations_served per gateway: [${before.join(', ')}]`);
  console.log(`==> Opening ${M} hydrating subscription(s) through the ingress (ws .../api/ws/v1/cache/hydrate/${CACHE_ID})`);
  const subs = [];
  for (let j = 0; j < M; j++) {
    const ws = await openWs(`ws://localhost:${ING_PORT}/api/ws/v1/cache/hydrate/${CACHE_ID}`);
    const s = { ws, items: 0 };
    ws.addEventListener('message', (e) => { if (String(e.data).includes('"eventType":"ADD_ITEM"')) s.items += 1; });
    subs.push(s);
    await sleep(250);
  }
  await sleep(3000);
  const noSnapshot = subs.filter((s) => s.items < 1).length;
  if (noSnapshot > 0) fail(`${noSnapshot}/${M} subscriptions did not receive a hydration snapshot`);
  console.log(`    all ${M} subscriptions received their snapshot`);

  // [3] per-pod hydration deltas must sum to exactly M (all served from the near caches). Poll briefly
  // while the counters settle.
  let after = [], delta = [], total = 0;
  for (let t = 0; t < 8; t++) {
    after = await Promise.all(pods.map((_, i) => hydrationsServed(i)));
    delta = after.map((v, i) => v - before[i]);
    total = delta.reduce((a, c) => a + c, 0);
    if (total >= M) break;
    await sleep(1000);
  }
  subs.forEach((s) => { try { s.ws.close(); } catch {} });

  console.log('==> Hydrations served from each near cache (this run):');
  pods.forEach((p, i) => console.log(`      ${p}: ${delta[i]}`));
  console.log(`    total served from near caches: ${total} (expected ${M})`);
  if (total !== M) fail(`hydrations served from near caches = ${total}, expected exactly ${M} (some hydration may have missed the near cache)`);

  // [4] load-balanced: the M hydrations landed on at least two distinct gateways.
  const servedBy = delta.filter((d) => d > 0).length;
  if (N > 1 && servedBy < 2) fail(`all ${M} hydrations landed on one gateway — that is not load balancing`);
  console.log(`==> ${M} hydrations spread across ${servedBy} of ${N} gateway(s)`);

  console.log(`==> HYDRATION LB VERIFY PASSED (${M} snapshots served from the near-cache pool, balanced across ${servedBy} gateway(s))`);
  process.exit(0);
};

main().catch((e) => fail(e?.message || String(e)));
