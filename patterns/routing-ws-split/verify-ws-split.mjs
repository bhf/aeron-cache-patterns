// Prove the ENDPOINT SPLIT for the routing-ws-split pattern.
//
// One WebSocket interface is split by endpoint role across two gateways that share one backend:
//   bidi    ws://.../api/ws/v1/bidi            -> aeroncache-ws-bidi    (read-write command channel)
//   stream  ws://.../api/ws/v1/cache/<id>      -> aeroncache-ws-stream  (plain subscribe)
//   stream  ws://.../api/ws/v1/cache/hydrate/<id> -> aeroncache-ws-stream (hydrating subscribe: snapshot first)
// Both gateways run the SAME image, so "does the endpoint work" cannot tell them apart — only WHERE the
// ingress sent the request differs. So each landing is proven with a per-gateway metric scraped from
// that gateway's own /prometheus, and the end-to-end data flow is proven by a cross-gateway round-trip.
//
// Asserts (all traffic goes THROUGH the ingress):
//   1. bidi -> bidi gateway       — seed the cache over the ingress bidi endpoint; aeroncache_operations_total
//                                    rises on the bidi gateway and NOT on the stream gateway.
//   2. subscribe -> stream gateway — open a subscription over the ingress; aeroncache_subscriptions_active
//                                    rises on the stream gateway and NOT on the bidi gateway.
//   3. shared backend (end-to-end) — with that subscription open, write a fresh value over the bidi
//                                    socket (bidi gateway) and see it pushed to the subscription (stream
//                                    gateway) — proving one backend behind the two gateways.
//   4. hydrate -> stream gateway   — prime the stream gateway's near cache, then open M hydrating
//                                    subscriptions over the ingress; each receives its snapshot, and
//                                    aeroncache_near_hydrations_served_total rises on the stream gateway
//                                    by M (served warm) while the bidi gateway serves 0 (near cache off).
//
// Run by `make verify` via common/smoke.sh (SMOKE_MODE=command). smoke.sh health-gates the stream
// gateway Service; this script owns its own port-forwards (the ingress controller + each gateway
// Service). Node 22+ (global WebSocket + fetch).
import { spawn } from 'node:child_process';

const NAMESPACE = process.env.NAMESPACE || 'aeroncache-patterns';
const CACHE_ID = process.env.CACHE_ID || 'routing-ws-split';
const SEED_ITEMS = Number(process.env.SEED_ITEMS || 5);
const HYDRATIONS = Number(process.env.HYDRATIONS || 4);
const ING_PORT = 18080, BIDI_PORT = 17081, STREAM_PORT = 17082;
const ING = `ws://localhost:${ING_PORT}`;
const BIDI_BASE = `http://localhost:${BIDI_PORT}`;
const STREAM_BASE = `http://localhost:${STREAM_PORT}`;
const WARM_TIMEOUT_MS = Number(process.env.WARM_TIMEOUT_MS || 40000);

const fail = (m) => { console.error(`WS SPLIT VERIFY FAILED: ${m}`); process.exit(1); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- port-forwards (owned by this script) -----------------------------------
const forwards = [];
const portForward = (ns, target, mapping) => forwards.push(spawn('kubectl', ['port-forward', '-n', ns, target, mapping], { stdio: 'ignore' }));
const cleanup = () => { for (const p of forwards) { try { p.kill(); } catch {} } };
process.on('exit', cleanup);
process.on('SIGINT', () => { cleanup(); process.exit(1); });

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

// Send a command frame over the bidi socket; resolve with the commandResponse for its correlationId.
function rpc(ws, frame) {
  return new Promise((resolve, reject) => {
    const to = setTimeout(() => reject(new Error(`timeout waiting for ${frame.op}`)), 12000);
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

// Sum every non-comment /prometheus sample whose line starts with `prefix` (across label variants).
async function metricSum(base, prefix) {
  const res = await fetch(`${base}/prometheus`).catch(() => null);
  if (!res || !res.ok) return 0;
  const text = await res.text();
  let sum = 0;
  for (const line of text.split('\n')) {
    if (line.startsWith('#') || !line.startsWith(prefix)) continue;
    const v = Number(line.trim().split(/\s+/).pop());
    if (!Number.isNaN(v)) sum += v;
  }
  return sum;
}
const operations = (base) => metricSum(base, 'aeroncache_operations_total');
const subscriptions = (base) => metricSum(base, 'aeroncache_subscriptions_active');
const hydrations = (base) => metricSum(base, 'aeroncache_near_hydrations_served_total');

async function warmItemCount(base) {
  const res = await fetch(`${base}/api/v1/near/caches`).catch(() => null);
  if (!res || !res.ok) return 0;
  const list = await res.json().catch(() => []);
  const hit = (Array.isArray(list) ? list : []).find((c) => c.cacheId === CACHE_ID);
  return hit ? Number(hit.itemCount || 0) : 0;
}

const main = async () => {
  console.log('==> Port-forwarding the ingress controller + both gateway Services');
  portForward('ingress-nginx', 'svc/ingress-nginx-controller', `${ING_PORT}:80`);
  portForward(NAMESPACE, 'svc/aeroncache-ws-bidi', `${BIDI_PORT}:7071`);
  portForward(NAMESPACE, 'svc/aeroncache-ws-stream', `${STREAM_PORT}:7071`);
  await sleep(6000);

  // --- 1. bidi -> bidi gateway: seed over the ingress bidi endpoint, watch ops land on the bidi gw ---
  const opsBidiBefore = await operations(BIDI_BASE);
  const opsStreamBefore = await operations(STREAM_BASE);
  console.log(`==> [1] Seeding '${CACHE_ID}' with ${SEED_ITEMS} item(s) over the ingress bidi endpoint`);
  const bidi = await openWs(`${ING}/api/ws/v1/bidi`);
  try { await rpc(bidi, { type: 'command', op: 'CREATE_CACHE', correlationId: 'c', cacheId: CACHE_ID }); }
  catch (e) { console.log(`    create note: ${e.message} (continuing)`); }
  for (let k = 0; k < SEED_ITEMS; k++) {
    const r = await rpc(bidi, { type: 'command', op: 'ADD_CACHE_ENTRY', correlationId: `a${k}`, cacheId: CACHE_ID, key: `key${k}`, value: `val${k}` });
    if (r.status !== 'SUCCESS') fail(`seed add key${k} status ${r.status}`);
  }
  // Poll the per-gateway operation counters while they settle.
  let opsBidiD = 0, opsStreamD = 0;
  for (let t = 0; t < 8; t++) {
    opsBidiD = (await operations(BIDI_BASE)) - opsBidiBefore;
    opsStreamD = (await operations(STREAM_BASE)) - opsStreamBefore;
    if (opsBidiD >= SEED_ITEMS) break;
    await sleep(1000);
  }
  console.log(`    operations delta — bidi gateway: ${opsBidiD}, stream gateway: ${opsStreamD}`);
  if (opsBidiD < SEED_ITEMS) fail(`bidi gateway recorded only ${opsBidiD} operations (expected >= ${SEED_ITEMS}) — bidi did not route to the bidi gateway`);
  if (opsStreamD >= opsBidiD) fail(`stream gateway recorded ${opsStreamD} operations vs bidi gateway ${opsBidiD} — bidi traffic is not isolated to the bidi gateway`);
  console.log('    bidi endpoint routed to the bidi gateway');

  // --- 2. subscribe -> stream gateway: open a subscription over the ingress, watch subs land on stream gw ---
  const subBidiBefore = await subscriptions(BIDI_BASE);
  const subStreamBefore = await subscriptions(STREAM_BASE);
  console.log(`==> [2] Subscribing over the ingress (ws .../api/ws/v1/cache/${CACHE_ID})`);
  const sub = await openWs(`${ING}/api/ws/v1/cache/${CACHE_ID}`);
  const subFrames = [];
  sub.addEventListener('message', (e) => subFrames.push(typeof e.data === 'string' ? e.data : String(e.data)));
  let subBidiD = 0, subStreamD = 0;
  for (let t = 0; t < 8; t++) {
    subBidiD = (await subscriptions(BIDI_BASE)) - subBidiBefore;
    subStreamD = (await subscriptions(STREAM_BASE)) - subStreamBefore;
    if (subStreamD >= 1) break;
    await sleep(1000);
  }
  console.log(`    active-subscriptions delta — bidi gateway: ${subBidiD}, stream gateway: ${subStreamD}`);
  if (subStreamD < 1) fail('stream gateway did not register the subscription — subscribe did not route to the stream gateway');
  if (subBidiD >= 1) fail(`bidi gateway registered the subscription (delta ${subBidiD}) — subscribe is not isolated to the stream gateway`);
  console.log('    subscribe endpoint routed to the stream gateway');

  // --- 3. shared backend: write over the bidi socket (bidi gw), see it pushed to the subscription (stream gw) ---
  console.log('==> [3] Writing a fresh value over bidi, expecting it on the stream subscription (shared backend)');
  const live = `live-${Date.now()}`;
  const w = await rpc(bidi, { type: 'command', op: 'ADD_CACHE_ENTRY', correlationId: 'live', cacheId: CACHE_ID, key: 'liveKey', value: live });
  if (w.status !== 'SUCCESS') fail(`live write status ${w.status}`);
  let seen = false;
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    if (subFrames.some((f) => f.includes(live))) { seen = true; break; }
    await sleep(250);
  }
  if (!seen) fail('the stream subscription never received the value written over the bidi gateway — the two gateways are not sharing one backend');
  console.log('    write on the bidi gateway reached the subscription on the stream gateway');
  try { sub.close(); } catch {}

  // --- 4. hydrate -> stream gateway, served warm: prime the stream near cache, then hydrate over the ingress ---
  console.log(`==> [4] Priming the stream gateway near cache (POST ${STREAM_BASE}/api/v1/near/cache/${CACHE_ID})`);
  const prime = await fetch(`${STREAM_BASE}/api/v1/near/cache/${CACHE_ID}`, { method: 'POST' }).catch(() => null);
  if (!prime || !prime.ok) fail(`prime failed (HTTP ${prime ? prime.status : 'no response'}) — is the stream gateway's near cache enabled?`);
  console.log(`==> Waiting up to ${WARM_TIMEOUT_MS / 1000}s for the stream gateway to be warm with >= ${SEED_ITEMS} item(s)`);
  let items = 0;
  const wd = Date.now() + WARM_TIMEOUT_MS;
  while (Date.now() < wd) {
    items = await warmItemCount(STREAM_BASE);
    if (items >= SEED_ITEMS) break;
    await sleep(2000);
  }
  if (items < SEED_ITEMS) fail(`stream gateway was not warm with >= ${SEED_ITEMS} items within ${WARM_TIMEOUT_MS / 1000}s (itemCount=${items})`);
  console.log(`    stream gateway holds ${items} item(s) warm locally`);

  const hydStreamBefore = await hydrations(STREAM_BASE);
  const hydBidiBefore = await hydrations(BIDI_BASE);
  console.log(`==> Opening ${HYDRATIONS} hydrating subscription(s) over the ingress (ws .../api/ws/v1/cache/hydrate/${CACHE_ID})`);
  const hsubs = [];
  for (let j = 0; j < HYDRATIONS; j++) {
    const ws = await openWs(`${ING}/api/ws/v1/cache/hydrate/${CACHE_ID}`);
    const s = { ws, items: 0 };
    ws.addEventListener('message', (e) => { if (String(e.data).includes('"eventType":"ADD_ITEM"')) s.items += 1; });
    hsubs.push(s);
    await sleep(250);
  }
  await sleep(3000);
  const noSnapshot = hsubs.filter((s) => s.items < 1).length;
  if (noSnapshot > 0) fail(`${noSnapshot}/${HYDRATIONS} hydrating subscriptions did not receive a snapshot`);
  console.log(`    all ${HYDRATIONS} hydrating subscriptions received their snapshot`);

  let hydStreamD = 0, hydBidiD = 0;
  for (let t = 0; t < 8; t++) {
    hydStreamD = (await hydrations(STREAM_BASE)) - hydStreamBefore;
    hydBidiD = (await hydrations(BIDI_BASE)) - hydBidiBefore;
    if (hydStreamD >= HYDRATIONS) break;
    await sleep(1000);
  }
  hsubs.forEach((s) => { try { s.ws.close(); } catch {} });
  try { bidi.close(); } catch {}
  console.log(`    near hydrations-served delta — stream gateway: ${hydStreamD}, bidi gateway: ${hydBidiD}`);
  if (hydStreamD !== HYDRATIONS) fail(`stream gateway served ${hydStreamD} hydrations from its near cache, expected exactly ${HYDRATIONS}`);
  if (hydBidiD !== 0) fail(`bidi gateway served ${hydBidiD} hydrations — hydrate is not isolated to the stream gateway`);
  console.log('    hydrate endpoint routed to the stream gateway and served warm');

  console.log('==> WS SPLIT VERIFY PASSED (bidi->bidi gw, subscribe+hydrate->stream gw, one shared backend)');
  process.exit(0);
};

main().catch((e) => fail(e?.message || String(e)));
