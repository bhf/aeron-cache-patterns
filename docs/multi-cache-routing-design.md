# Multi-cache routing — design note

**Status:** exploration (no pattern built yet) · **Date:** 2026-11-21 · **Branch:** `multi-cache`

This note captures the design space for a **multi-cache** pattern: running several cache backends
(clustered or ephemeral) behind a single entry point, and routing a request to the right one. It
records the constraint that forces the question, three candidate designs, a per-interface
routability analysis verified against the upstream `aeron-cache` source, and the trade-offs that
separate the options. It exists so the reasoning survives before any code is written.

> All upstream references below are to the **`aeron-cache`** repo (the app that ships the
> `ghcr.io/bhf/aeroncache-*` images this repo deploys), checked on `main`. This patterns repo builds
> nothing, so any change marked "upstream" is a change to that app + a new image.

---

## 1. The constraint

Every interface/gateway binds to **exactly one backend** at install time. The http chart takes
`clusterAddresses` + `cacheMode` (and, for ephemeral, the response-channel endpoints) as fixed
values; there is one Aeron client session to one cache. So "N caches" means **N backends + N
gateways**, wired in pairs:

```
aeroncache-cluster-a  ←  aeroncache-http-a
aeroncache-cluster-b  ←  aeroncache-http-b
```

Plumbing the single-instance patterns don't do yet (they deploy exactly one of each):

- `fullnameOverride` is hardcoded (e.g. `aeroncache-http`) and the Service selects the
  `<workloadName>-0` pod — two releases collide; each instance needs a distinct name.
- The backend's `clusterAddresses` default is templated to one release's pods; instance B's gateway
  must point at B's pods.
- Aeron is UDP pod-to-pod, so this stays headless / pod-IP addressed, exactly as the ephemeral path
  already is.

None of that is hard — it is mostly parametrising names the single-instance patterns got to leave
constant.

## 2. Terminology (the source of most confusion)

The app **already** multiplexes many **logical caches** inside one backend:
`POST /api/v1/cache {cacheId}` then `/api/v1/cache/<cacheId>/<key>`. That `cacheId` is a logical
cache **within one backend**, not a routing key to a different deployment.

So "route by cache id" splits two ways:

- **Instance id** — a deploy-time name (`a`, `b`), a finite known set. Static routing.
- **Logical cacheId** — the app's own runtime id. Dynamic routing (sharding the logical cache space
  across backends).

These are different patterns with very different costs.

## 3. The three designs

### A — Instance prefix (static)

Put an instance selector at the **front** of the URL and strip it:

```
/a/api/v1/cache/foo/k  →  rewrite /api/v1/cache/foo/k  →  svc aeroncache-http-a
/b/...                 →  ...                          →  svc aeroncache-http-b
```

One nginx Ingress, two path rules with `rewrite-target`. The routing key is a finite, known set, so
a static rule suffices. **Routes the whole request/connection by instance; never reads the cache
id.** Works with today's images, no upstream change. First pattern in the repo to use an ingress
controller (minikube `ingress` addon / kind's ingress-nginx).

Cost: **no transparency** — the client must know which instance a cache lives on.

### B — External shard router (dynamic, by logical cacheId)

An L7 layer extracts the cacheId from the request and routes by `backend = hash(cacheId) mod N`.

- A plain Ingress **cannot** do this — it matches static rules and can rewrite, but cannot *compute*
  a backend from a captured value, and cacheIds are unbounded so you can't enumerate them.
- Needs a layer that runs logic: **nginx + Lua** (lightest), **Envoy ring-hash** (natural fit,
  heaviest), or a **small custom router** (most control, most code).
- Requires **upstream API changes** (see §4) and **amputates features** (see §5).

### C — Multi-backend gateway (dynamic, routing moved into the gateway)

Make each gateway hold client sessions to **all N backends** and pick one per request. The enabler:
the gateway **already decodes every request to the cacheId level** — it parses the HTTP body to
build the SBE `cacheRequest`, and decodes each bidi frame to a `BidiCommand` with a `cacheId`. So
unlike an L7 router it can see the id *wherever it lives* (URL, body, or frame).

This dissolves the external-routing problem and **needs no client-facing API change** — clients keep
using `cacheId` as today; the gateway does placement. It also **recovers** the features B has to drop
(bidi, multi-subscribe, global list), because the gateway is the natural fan-in/out point.

Cost: it is the **biggest upstream change** (reworks the gateway core from one session to N + a
placement layer + stream/fanout merge + bulk splitting, across the shared `cache-client`/`cache-spi`
plumbing) and it **changes the gateway's failure/scaling profile** (see §7).

## 4. The create collision (why B needs an API change)

Current cache routes (`aeron-cache`:
`cache-http/http-server-javalin/.../HttpApplication.java:445-457`):

| Verb + path | Handler | cacheId location |
|---|---|---|
| `POST /api/v1/cache/` | createCache | **body** |
| `GET /api/v1/cache/<cacheId>/<key>` | getItem | URL |
| `GET /api/v1/cache/<cacheId>` | getCache | URL |
| `POST /api/v1/cache/<cacheId>` | **putItem** | URL |
| `POST /api/v1/cache/timed/<cacheId>` | putTimedItem | URL (after a verb segment) |
| `POST /api/v1/cache/<cacheId>/<key>/cancel-removal` | cancelItemRemoval | URL (mid-path) |
| `DELETE/PATCH /api/v1/cache/<cacheId>[/<key>]` | delete/clear/patch | URL |
| `POST /api/v1/cache/bulkops/` | bulkOps | **per-op (body)** |

Two consequences for an L7 router (design B):

1. **Create is body-only**, and it **cannot** be moved to `POST /api/v1/cache/<cacheId>` because
   that path+verb is already **putItem**. The fix is a different verb (`PUT /api/v1/cache/<cacheId>`
   = create/ensure) or a new subpath — an upstream change.
2. **The id is not always in a fixed slot** (`timed/<id>`, `increment/<id>`, `cancel-removal`
   mid-path), so a shard-key regex needs alternation, not a fixed segment index.

Design C needs **none** of this — the gateway reads the cacheId from the body on create directly.

## 5. Per-interface routability (verified)

Whether a layer can route depends on when it can read the cacheId. An L7 router reads it **once**:
per-request for http, **at connect** for a stream (then the connection is pinned to one backend).
The gateway (design C) reads it **continuously** (every request, every frame).

| Operation | Example | L7 router (B) | Multi-backend gateway (C) |
|---|---|---|---|
| Per-cache read/write/delete/patch | `GET/POST /cache/<id>[/<key>]` | ✅ id in URL | ✅ |
| Counters (mirror of caches) | `/counters/<id>`, `ws .../counter/{id}` | ✅ | ✅ |
| Per-cache near prime/stop | `POST /near/cache/<id>` | ✅ | ✅ |
| SSE/WS **single**-cache subscribe | `.../cache/{cacheId}` | ✅ at connect | ✅ |
| **HTTP create** | `POST /api/v1/cache/` | ❌ id in body | ✅ gateway reads body |
| **SSE/WS multi-cache subscribe** | `.../caches/{cacheIds}` (plural) | ❌ one conn, many caches | ✅ subscribe per-backend, merge |
| **WS bidi** | `/api/ws/v1/bidi` | ❌ per-frame id, multiplexed | ✅ decode frame, route, demux by correlationId |
| **Global list / stats** | `/caches`, `/stats`, `/timers`, `/counters-caches`, `/snapshot-info`, `/aeron-counters` | ❌ fanout+merge | ✅ gateway queries all, merges |
| **Cluster-wide admin** | `/shutdown`, `/snapshot`, `/snapshot-and-purge` | ❌ per-backend | ⚠️ per-backend or gateway fan-out |
| **clustertools** | `/api/v1/clustertools/*` | ❌ separate sidecar, per-backend | ⚠️ aggregate or expose per-backend |
| **HTTP bulkops** | `POST /cache/bulkops/` | ❌ per-op cacheId, spans shards | ⚠️ routable but semantics change (§6) |

Route sources: http `HttpApplication.java:445-468`; SSE
`cache-sse/sse-server-jooby/.../SSEApplication.java:141-164`; WS
`cache-ws/ws-server-javalin/.../WebsocketApplication.java:308-326`. The multi-cache subscribe
(`.../caches/{cacheIds}`) and bidi (`/api/ws/v1/bidi`) endpoints are what make the streaming
interfaces resist external sharding — both fan one connection across caches.

**Takeaway:** design C routes essentially everything the external router (B) can't, because it sees
bodies and frames and is the natural aggregation point. Bulk is the lone real exception.

## 6. Bulk ops — the one leak in design C

`handleBulkOpsRequest` (`HttpApplication.java:497`) decodes a `List<CacheOperationRequest>` — each op
carrying **its own `cacheId`** (`cache-spi/.../CacheOperationRequest.java`) — and calls
`sendBulkOperationsRequest(requestId, request, consumer)`: **one publish, one correlation id, one
aggregated response**.

The gateway *can* split a batch by each op's backend and send sub-batches — so bulk is **routable**.
What changes is **semantics**:

- **Atomicity/isolation:** the batch no longer lands as one unit on one state machine; sub-batches
  apply independently and concurrently on different clusters.
- **Partial failure:** backend A's sub-batch can succeed while B's fails — no cross-cluster
  transaction. One OK/ERROR becomes a merge of N partial outcomes.
- **Ordering:** ops currently flow to one cluster in order; across clusters they are concurrent.

Options: accept per-shard sub-batch semantics (document it), or reject cross-shard bulks (a bulk
whose ops share a backend works unchanged; a mixed one is a 400).

## 7. Placement and operational trade-offs (B and C)

- **Placement:** `hash(cacheId) mod N` (stateless, deterministic) vs a registry (flexible, stateful).
  With more than one gateway/router replica, replicas must **agree** on placement — pure hash makes
  them agree for free, so it is strongly preferred. A registry must be replicated and kept
  consistent.
- **Resharding:** `mod N` remaps most ids when N changes, and **nothing migrates data** between these
  independent clusters — the data is simply on the wrong backend now. Consistent hashing (ring-hash)
  minimises the reshuffle but still doesn't move data. **Shard count is effectively fixed** unless you
  build migration. Fine for a fixed-N demo; a real caveat for a "pattern".
- **Failure isolation (C only):** today a gateway fails with its one backend. A multi-backend gateway
  is a **shared dependency** for all backends — the gateway tier being unhealthy hits everything, and
  a slow/dead backend can cause head-of-line blocking / resource pressure in a gateway also serving
  healthy ones. It also holds Aeron sessions to every backend (media-driver resource concentration).
  Designs A and B keep gateway↔backend as isolated pairs.

## 8. Comparison

| | A — instance prefix | B — external shard router | C — multi-backend gateway |
|---|---|---|---|
| Routing key | instance (static) | logical cacheId (hash) | logical cacheId (hash), in-gateway |
| Transparency to client | ❌ client picks instance | ✅ | ✅ |
| Client-facing API change | none | **yes** (create verb, …) | **none** |
| External routing infra | nginx Ingress (regex rewrite) | Envoy / nginx+Lua / custom | none (one Service as today) |
| Upstream app change | none | route signatures | **large** (gateway core rework) |
| Works with today's images | ✅ | ❌ | ❌ |
| bidi / multi-subscribe / global-list | ✅ (routed by instance) | ❌ dropped | ✅ recovered |
| bulk ops | ✅ (per instance) | ❌ | ⚠️ semantics change |
| Failure isolation | ✅ pairs | ✅ pairs | ❌ shared hub |
| Resharding / data migration | n/a (independent instances) | ⚠️ fixed N | ⚠️ fixed N |

## 9. Recommendation

- **Ship A first.** It is small, self-contained, works with the public images today, and honestly
  demonstrates "N caches behind one entry point, routed by URL." It is the first pattern to stand up
  an ingress controller, which is itself worth showing.
- **Treat C as the aspirational dynamic design**, not B. C is the elegant answer to transparent
  per-cacheId routing — it needs no client-facing API change and recovers the streaming features —
  but it is a substantial upstream gateway rework and changes the gateway's failure/scaling profile.
  Bulk ops are the single semantic compromise; placement is fixed-N without a migration story.
- **B is the least attractive** of the dynamic options: it needs client-facing API changes *and*
  external routing infra *and* drops bidi/multi-subscribe/bulk/global-list — strictly more cost and
  less capability than C.

## Appendix — verified upstream references (`aeron-cache`, `main`)

- HTTP routes: `cache-http/http-server-javalin/src/main/java/com/bhf/aeroncache/http/application/HttpApplication.java:445-468`
- HTTP bulk handler: same file, `:497`; op schema `cache-spi/src/main/java/com/bhf/aeroncache/models/bulk/requests/CacheOperationRequest.java`
- SSE routes: `cache-sse/sse-server-jooby/src/main/java/com/bhf/aeroncache/sse/application/SSEApplication.java:141-164`
- WS routes: `cache-ws/ws-server-javalin/src/main/java/com/bhf/aeroncache/ws/application/WebsocketApplication.java:308-326`
- `clustertools` is a separate sidecar reached per-host on the cluster-tools port (per-backend diagnostics).
