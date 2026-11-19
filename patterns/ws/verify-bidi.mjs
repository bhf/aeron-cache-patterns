// Bidi WebSocket round-trip smoke for the ws interface.
//
// Connects to the bidirectional endpoint (/api/ws/v1/bidi), creates a cache, puts an item, reads
// it back, and asserts the value — the ws-native equivalent of the HTTP create/put/get smoke.
// Run by `make verify` via common/smoke.sh (SMOKE_MODE=command), which first port-forwards the ws
// Service and passes LOCAL_PORT in the environment. Uses Node's global WebSocket (Node >= 22).
//
// Env: LOCAL_PORT (forwarded ws port), CACHE_ID, WS_URL (override), WS_TIMEOUT_MS.

const PORT = process.env.LOCAL_PORT || '7071';
const CACHE_ID = process.env.CACHE_ID || 'smoke-ws';
const URL = process.env.WS_URL || `ws://localhost:${PORT}/api/ws/v1/bidi`;
const TIMEOUT_MS = Number(process.env.WS_TIMEOUT_MS || 15000);

const fail = (m) => { console.error(`BIDI SMOKE FAILED: ${m}`); process.exit(1); };

// Connect with a few retries, since the port-forward / server may need a moment.
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

// Send a command frame and resolve with the commandResponse matching its correlationId.
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

const main = async () => {
  console.log(`==> Connecting to ${URL}`);
  const ws = await connect(URL);

  console.log(`==> CREATE_CACHE '${CACHE_ID}'`);
  // Tolerate "already exists" on a re-run against a live cluster.
  try {
    const r = await rpc(ws, { type: 'command', op: 'CREATE_CACHE', correlationId: 'c-create', cacheId: CACHE_ID });
    console.log(`    create status: ${r.status}`);
  } catch (e) {
    console.log(`    create note: ${e.message} (continuing)`);
  }

  console.log('==> ADD_CACHE_ENTRY (testKey=testValue)');
  const add = await rpc(ws, { type: 'command', op: 'ADD_CACHE_ENTRY', correlationId: 'c-add', cacheId: CACHE_ID, key: 'testKey', value: 'testValue' });
  if (add.status !== 'SUCCESS') fail(`add status ${add.status}`);

  console.log('==> GET_CACHE_ENTRY');
  const got = await rpc(ws, { type: 'command', op: 'GET_CACHE_ENTRY', correlationId: 'c-get', cacheId: CACHE_ID, key: 'testKey' });
  console.log(`    get -> status=${got.status} value=${got.value}`);
  if (got.value !== 'testValue') fail(`expected 'testValue', got '${got.value}' (status ${got.status})`);

  ws.close();
  console.log('==> BIDI ROUND-TRIP PASSED');
  process.exit(0);
};

main().catch((e) => fail(e?.message || String(e)));
