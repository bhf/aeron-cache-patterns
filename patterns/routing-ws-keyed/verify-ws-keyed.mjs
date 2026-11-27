// Prove the KEYED / WHOLE-CACHE subscription split for the routing-ws-keyed pattern.
//
// The WebSocket subscribe endpoint is split across two gateways that share one backend by whether the
// subscription is KEYED — i.e. by the `keys` query parameter, not the path:
//   keyed  ws://.../api/ws/v1/cache/<id>?keys=<key>  -> aeroncache-ws-keyed   (filtered to those keys)
//   stream ws://.../api/ws/v1/cache/<id>             -> aeroncache-ws-stream  (whole-cache stream)
// The split is decided in an ingress-nginx server-snippet from $arg_keys. Both gateways run the same
// image, so "does the subscription work" cannot tell them apart — only WHERE the ingress sent it
// differs, so each landing is proven with the per-gateway aeroncache_subscriptions_active gauge. A
// write over one gateway's bidi socket, seen on the other gateway's subscription, proves the shared
// backend; the keyed subscription's server-side filtering is proven by what it does and does not get.
//
// Asserts (subscriptions opened THROUGH the ingress):
//   1. keyed -> keyed gateway        — a ?keys= subscription raises subscriptions_active on the keyed
//                                      gateway and not on the stream gateway.
//   2. whole-cache -> stream gateway — a no-keys subscription raises subscriptions_active on the stream
//                                      gateway and not on the keyed gateway.
//   3. keyed filtering + shared backend — writing keyA, keyB, keyC over one gateway's bidi: the keyed
//                                      subscription (keys=keyA) gets ONLY keyA; the whole-cache
//                                      subscription gets keyB and keyC too. The whole-cache subscription
//                                      lives on the stream gateway while the write went in on the keyed
//                                      gateway's bidi, so one shared backend feeds both.
//
// Run by `make verify` via common/smoke.sh (SMOKE_MODE=command). smoke.sh health-gates the stream
// gateway Service; this script owns its own port-forwards (the ingress controller + each gateway
// Service). Node 22+ (global WebSocket + fetch).
import { spawn } from 'node:child_process';

const NAMESPACE = process.env.NAMESPACE || 'aeroncache-patterns';
const CACHE_ID = process.env.CACHE_ID || 'routing-ws-keyed';
const ING_PORT = 18080, KEYED_PORT = 17081, STREAM_PORT = 17082;
const KEYED_BASE = `http://localhost:${KEYED_PORT}`;
const STREAM_BASE = `http://localhost:${STREAM_PORT}`;
// keyA is the key the keyed subscription filters to; keyB/keyC are not subscribed by it.
const KEY_A = 'keyA', KEY_B = 'keyB', KEY_C = 'keyC';

const fail = (m) => { console.error(`WS KEYED VERIFY FAILED: ${m}`); process.exit(1); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- port-forwards (owned by this script) -----------------------------------
const forwards = [];
const portForward = (ns, target, mapping) => forwards.push(spawn('kubectl', ['port-forward', '-n', ns, target, mapping], { stdio: 'ignore' }));
const cleanup = () => { for (const p of forwards) { try { p.kill(); } catch {} } };
process.on('exit', cleanup);
process.on('SIGINT', () => { cleanup(); process.exit(1); });

// Retries generously: enabling allow-snippets can briefly reload/replace the ingress controller, so a
// subscription opened right after deploy may need a few seconds before the controller is back.
function openWs(url, attempts = 40) {
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

// Open a subscription and record every frame (for later needle checks).
function subscribe(url) {
  return openWs(url).then((ws) => {
    const frames = [];
    ws.addEventListener('message', (e) => frames.push(typeof e.data === 'string' ? e.data : String(e.data)));
    return { ws, frames, url };
  });
}
const saw = (sub, needle) => sub.frames.some((f) => f.includes(needle));

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

// Sum of aeroncache_subscriptions_active across label variants on a gateway's /prometheus (0 if absent).
async function subscriptions(base) {
  const res = await fetch(`${base}/prometheus`).catch(() => null);
  if (!res || !res.ok) return 0;
  const text = await res.text();
  let sum = 0;
  for (const line of text.split('\n')) {
    if (line.startsWith('#') || !line.startsWith('aeroncache_subscriptions_active')) continue;
    const v = Number(line.trim().split(/\s+/).pop());
    if (!Number.isNaN(v)) sum += v;
  }
  return sum;
}

// Poll a per-gateway subscriptions_active delta until the target gateway rises (or time runs out).
async function deltaWhenRaised(before, baseTarget, baseOther) {
  let dT = 0, dO = 0;
  for (let t = 0; t < 8; t++) {
    dT = (await subscriptions(baseTarget)) - before.target;
    dO = (await subscriptions(baseOther)) - before.other;
    if (dT >= 1) break;
    await sleep(1000);
  }
  return { dT, dO };
}

const main = async () => {
  console.log('==> Port-forwarding the ingress controller + both gateway Services');
  portForward('ingress-nginx', 'svc/ingress-nginx-controller', `${ING_PORT}:80`);
  portForward(NAMESPACE, 'svc/aeroncache-ws-keyed', `${KEYED_PORT}:7071`);
  portForward(NAMESPACE, 'svc/aeroncache-ws-stream', `${STREAM_PORT}:7071`);
  await sleep(6000);

  // Create the cache over the KEYED gateway's bidi socket (writes land on the shared backend). We'll
  // also drive the live writes from here, so a write on the keyed gateway proves the shared backend
  // when the stream gateway's subscription sees it.
  console.log(`==> Creating '${CACHE_ID}' over the keyed gateway's bidi endpoint`);
  const bidi = await openWs(`ws://localhost:${KEYED_PORT}/api/ws/v1/bidi`);
  try { await rpc(bidi, { type: 'command', op: 'CREATE_CACHE', correlationId: 'c', cacheId: CACHE_ID }); }
  catch (e) { console.log(`    create note: ${e.message} (continuing)`); }

  // --- 1. keyed subscription -> keyed gateway ---------------------------------------------------
  console.log(`==> [1] Opening a KEYED subscription over the ingress (…/api/ws/v1/cache/${CACHE_ID}?keys=${KEY_A})`);
  let beKeyed = await subscriptions(KEYED_BASE), beStream = await subscriptions(STREAM_BASE);
  const keyedSub = await subscribe(`ws://localhost:${ING_PORT}/api/ws/v1/cache/${CACHE_ID}?keys=${KEY_A}`);
  {
    const { dT, dO } = await deltaWhenRaised({ target: beKeyed, other: beStream }, KEYED_BASE, STREAM_BASE);
    console.log(`    subscriptions delta — keyed gateway: ${dT}, stream gateway: ${dO}`);
    if (dT < 1) fail('keyed gateway did not register the keyed subscription — ?keys= did not route to the keyed gateway');
    if (dO >= 1) fail(`stream gateway registered the keyed subscription (delta ${dO}) — keyed subscriptions are not isolated to the keyed gateway`);
  }
  console.log('    keyed subscription routed to the keyed gateway');

  // --- 2. whole-cache subscription -> stream gateway --------------------------------------------
  console.log(`==> [2] Opening a WHOLE-CACHE subscription over the ingress (…/api/ws/v1/cache/${CACHE_ID}, no keys)`);
  beKeyed = await subscriptions(KEYED_BASE); beStream = await subscriptions(STREAM_BASE);
  const streamSub = await subscribe(`ws://localhost:${ING_PORT}/api/ws/v1/cache/${CACHE_ID}`);
  {
    const { dT, dO } = await deltaWhenRaised({ target: beStream, other: beKeyed }, STREAM_BASE, KEYED_BASE);
    console.log(`    subscriptions delta — stream gateway: ${dT}, keyed gateway: ${dO}`);
    if (dT < 1) fail('stream gateway did not register the whole-cache subscription — a no-keys subscribe did not route to the stream gateway');
    if (dO >= 1) fail(`keyed gateway registered the whole-cache subscription (delta ${dO}) — whole-cache subscriptions are not isolated to the stream gateway`);
  }
  console.log('    whole-cache subscription routed to the stream gateway');

  // --- 3. keyed filtering + shared backend ------------------------------------------------------
  // Both subscriptions stream only FUTURE updates (no hydrate), so write the three keys now, with both
  // subscriptions already open. The writes go in over the KEYED gateway's bidi socket.
  console.log(`==> [3] Writing ${KEY_A}, ${KEY_B}, ${KEY_C} over bidi; checking what each subscription receives`);
  const vA = `A-${Date.now()}`, vB = `B-${Date.now()}`, vC = `C-${Date.now()}`;
  for (const [k, v] of [[KEY_A, vA], [KEY_B, vB], [KEY_C, vC]]) {
    const r = await rpc(bidi, { type: 'command', op: 'ADD_CACHE_ENTRY', correlationId: `w-${k}`, cacheId: CACHE_ID, key: k, value: v });
    if (r.status !== 'SUCCESS') fail(`write ${k} status ${r.status}`);
  }
  // Give the live updates time to propagate to both subscriptions.
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    if (saw(keyedSub, vA) && saw(streamSub, vB) && saw(streamSub, vC)) break;
    await sleep(250);
  }
  // Keyed subscription (keys=keyA): must see keyA, must NOT see keyB / keyC (server-side key filter).
  if (!saw(keyedSub, vA)) fail(`keyed subscription (keys=${KEY_A}) never received ${KEY_A}'s update`);
  if (saw(keyedSub, vB) || saw(keyedSub, vC)) fail(`keyed subscription received an unsubscribed key — the keyed filter is not being applied`);
  console.log(`    keyed subscription received ${KEY_A} only (filtered)`);
  // Whole-cache subscription (on the stream gateway) must see the keys written on the keyed gateway's
  // bidi — proving the whole-cache stream AND that one shared backend feeds both gateways.
  if (!(saw(streamSub, vB) && saw(streamSub, vC))) fail('whole-cache subscription did not receive keyB/keyC written over the other gateway — not a whole-cache stream, or the gateways are not sharing one backend');
  console.log(`    whole-cache subscription received ${KEY_B} and ${KEY_C} (written over the keyed gateway — shared backend)`);

  try { keyedSub.ws.close(); } catch {}
  try { streamSub.ws.close(); } catch {}
  try { bidi.close(); } catch {}

  console.log('==> WS KEYED VERIFY PASSED (keyed sub->keyed gw, whole-cache sub->stream gw, filtered, one shared backend)');
  process.exit(0);
};

main().catch((e) => fail(e?.message || String(e)));
