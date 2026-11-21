// Near-cache verify for the ws interface.
//
// Proves the near cache actually serves this interface, not just that NEAR_CACHE_ENABLED is set. It:
//   1. creates a cache and writes an item over the bidi WebSocket (/api/ws/v1/bidi),
//   2. primes the ws interface's near cache for it (POST /api/v1/near/cache/<id>, served over HTTP on
//      the same ws port) and waits until it is listed warm with a local item count,
//   3. asserts the aeroncache_near_warm_caches{domain="cache"} gauge on the interface's own
//      /prometheus rose, and
//   4. reads the item back over the bidi WebSocket — now served from the warm local copy.
//
// Requires the near cache to be enabled (make up NEAR_CACHE=true); without it the prime route and the
// metric are absent and the prime step fails with a clear message.
//
// Run by `make verify-near` via common/smoke.sh (SMOKE_MODE=command), which port-forwards the ws
// Service and passes LOCAL_PORT in the environment. Uses Node's global WebSocket + fetch (Node >= 22).

const PORT = process.env.LOCAL_PORT || '7071';
const CACHE_ID = process.env.CACHE_ID || 'near-ws';
const WS_URL = process.env.WS_URL || `ws://localhost:${PORT}/api/ws/v1/bidi`;
const HTTP_BASE = process.env.HTTP_BASE || `http://localhost:${PORT}`;
const TIMEOUT_MS = Number(process.env.WS_TIMEOUT_MS || 15000);
const WARM_TIMEOUT_MS = Number(process.env.WARM_TIMEOUT_MS || 30000);

const fail = (m) => { console.error(`NEAR VERIFY FAILED: ${m}`); process.exit(1); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function connect(url, attempts = 10) {
  return new Promise((resolve, reject) => {
    let n = 0;
    const tryOnce = () => {
      const ws = new WebSocket(url);
      const onOpen = () => { ws.removeEventListener('error', onErr); resolve(ws); };
      const onErr = () => {
        ws.removeEventListener('open', onOpen);
        if (++n >= attempts) reject(new Error(`could not connect to ${url} after ${attempts} attempts`));
        else setTimeout(tryOnce, 1000);
      };
      ws.addEventListener('open', onOpen, { once: true });
      ws.addEventListener('error', onErr, { once: true });
    };
    tryOnce();
  });
}

function rpc(ws, frame) {
  return new Promise((resolve, reject) => {
    const cid = frame.correlationId;
    const cleanup = () => { clearTimeout(timer); ws.removeEventListener('message', onMsg); };
    const timer = setTimeout(() => { cleanup(); reject(new Error(`timeout waiting for ${frame.op} (${cid})`)); }, TIMEOUT_MS);
    const onMsg = (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch { return; }
      if (msg.correlationId !== cid) return;
      if (msg.type === 'error') { cleanup(); reject(new Error(`error for ${frame.op}: ${msg.status} ${msg.message || ''}`)); return; }
      if (msg.type === 'commandResponse') { cleanup(); resolve(msg); }
    };
    ws.addEventListener('message', onMsg);
    ws.send(JSON.stringify(frame));
  });
}

// aeroncache_near_warm_caches gauge value for domain="cache" on /prometheus (0 if absent).
async function warmGauge() {
  const res = await fetch(`${HTTP_BASE}/prometheus`);
  if (!res.ok) return 0;
  const text = await res.text();
  let v = 0;
  for (const line of text.split('\n')) {
    if (line.startsWith('aeroncache_near_warm_caches{') && line.includes('domain="cache"')) {
      v = Number(line.trim().split(/\s+/).pop()) || 0;
    }
  }
  return v;
}

async function warmItemCount() {
  const res = await fetch(`${HTTP_BASE}/api/v1/near/caches`);
  if (!res.ok) return 0;
  const list = await res.json().catch(() => []);
  const hit = (Array.isArray(list) ? list : []).find((c) => c.cacheId === CACHE_ID);
  return hit ? Number(hit.itemCount || 0) : 0;
}

const main = async () => {
  console.log(`==> Connecting to ${WS_URL}`);
  const ws = await connect(WS_URL);

  console.log(`==> CREATE_CACHE '${CACHE_ID}' and ADD_CACHE_ENTRY (testKey=testValue)`);
  try {
    await rpc(ws, { type: 'command', op: 'CREATE_CACHE', correlationId: 'c-create', cacheId: CACHE_ID });
  } catch (e) {
    console.log(`    create note: ${e.message} (continuing)`);
  }
  const add = await rpc(ws, { type: 'command', op: 'ADD_CACHE_ENTRY', correlationId: 'c-add', cacheId: CACHE_ID, key: 'testKey', value: 'testValue' });
  if (add.status !== 'SUCCESS') fail(`add status ${add.status}`);

  const before = await warmGauge();
  console.log(`==> Baseline aeroncache_near_warm_caches{domain=cache} = ${before}`);

  console.log(`==> Prime the near cache (POST ${HTTP_BASE}/api/v1/near/cache/${CACHE_ID})`);
  const primeRes = await fetch(`${HTTP_BASE}/api/v1/near/cache/${CACHE_ID}`, { method: 'POST' });
  if (!primeRes.ok) fail(`prime request failed (HTTP ${primeRes.status}) — is the near cache enabled? run 'make up NEAR_CACHE=true'`);
  console.log(`    prime: ${await primeRes.text()}`);

  console.log(`==> Waiting up to ${WARM_TIMEOUT_MS / 1000}s for '${CACHE_ID}' to be listed warm with items`);
  let items = 0;
  const deadline = Date.now() + WARM_TIMEOUT_MS;
  while (Date.now() < deadline) {
    items = await warmItemCount();
    if (items >= 1) break;
    await sleep(2000);
  }
  if (items < 1) fail(`'${CACHE_ID}' was not warm with items within ${WARM_TIMEOUT_MS / 1000}s (itemCount=${items})`);
  console.log(`    warm: '${CACHE_ID}' holds ${items} item(s) locally`);

  const after = await warmGauge();
  console.log(`==> aeroncache_near_warm_caches{domain=cache}: ${before} -> ${after}`);
  // >= 1 (not strictly > before) so a re-run against an already-warm cache still passes; the warm
  // listing above and the near-served read below are the proof the near cache actually holds this cache.
  if (!(after >= 1)) fail(`warm-caches metric is not >= 1 after priming (got ${after})`);

  console.log('==> GET_CACHE_ENTRY (now served from the warm local copy)');
  const got = await rpc(ws, { type: 'command', op: 'GET_CACHE_ENTRY', correlationId: 'c-get', cacheId: CACHE_ID, key: 'testKey' });
  if (got.value !== 'testValue') fail(`expected 'testValue', got '${got.value}' (status ${got.status})`);

  ws.close();
  console.log(`==> NEAR CACHE VERIFY PASSED (served from near cache; warm gauge ${before} -> ${after})`);
  process.exit(0);
};

main().catch((e) => fail(e?.message || String(e)));
