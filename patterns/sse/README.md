# SSE interface

> A backend plus the Server-Sent Events streaming interface — with an http writer alongside, since
> SSE is read-only.

## Overview

This pattern deploys an Aeron Cache **backend** and the **SSE interface** (`aeroncache-sse`), which
streams cache (and counter) updates to subscribers over Server-Sent Events. A client subscribes to
a cache — optionally with **hydration** (a snapshot on subscribe) — and then receives a live stream
of updates.

SSE is **uni-directional**: it is read-only, with no way to create caches or write items. So this
pattern also deploys the **HTTP interface** (`aeroncache-http`) as the **writer** — the realistic
shape, since an SSE consumer always needs something producing the data. The verify writes via http
and reads the result back over SSE.

`CACHE_TYPE` picks the backend — **`clustered`** (3-node RAFT, default) or **`ephemeral`**
(single-node SINGLE); both interfaces are wired to the same backend.

## Architecture

```mermaid
flowchart LR
  writer([Writer]) -->|"HTTP write :7070"| http["aeroncache-http"]
  sse["aeroncache-sse · :7072"] -->|"SSE events (subscribe / hydrate)"| reader([Reader])
  http ==>|Aeron| backend[("Backend<br/>clustered or ephemeral")]
  sse ==>|Aeron| backend
```

The sse interface exposes the SSE subscription routes (`/api/sse/v1/cache/...`,
`/api/sse/v1/cache/hydrate/...`) plus `/liveness/` and `/readiness/` on port 7072; it has no HTTP
REST data path.

## Prerequisites

- A local Kubernetes cluster via **minikube** (the default) — see the [repo README](../../README.md).
- `kubectl`, `helm`, `curl`, `jq`. Run `make doctor`.
- Clustered runs 5 pods (3 cluster nodes + sse + http); ephemeral runs 3.

## Run

```bash
make up                       # clustered backend + sse interface (+ http writer)
# or
make up CACHE_TYPE=ephemeral  # single-node ephemeral backend + sse interface (+ http writer)

make verify                   # write via http, then read it back over an SSE subscription
```

To use kind instead (as CI does): add `CLUSTER=kind`.

## Verify

`make verify` ([`verify-sse.sh`](verify-sse.sh)) port-forwards both the sse interface (7072) and the
http writer (7070), checks the sse interface's liveness/readiness, then:

1. creates a cache and puts `testKey=testValue` via **http**, and
2. subscribes to that cache over **SSE** with hydration (`/api/sse/v1/cache/hydrate/<id>`),

asserting the value streams back. A healthy deployment ends with `SSE ROUND-TRIP PASSED` then
`SMOKE PASSED`.

### Try it by hand

With both port-forwards up, in one terminal subscribe:

```bash
curl -N http://localhost:7072/api/sse/v1/cache/hydrate/demo
```

and in another, write — the event appears in the first:

```bash
curl -X POST http://localhost:7070/api/v1/cache -H 'Content-Type: application/json' -d '{"cacheId":"demo"}'
curl -X POST http://localhost:7070/api/v1/cache/demo -H 'Content-Type: application/json' -d '{"key":"k","value":"v"}'
```

## Near cache (optional)

The sse interface can serve **hydrating subscriptions** (snapshot-on-subscribe) from a **server-side
near cache** — a warm local copy kept in sync by a cluster subscription, so hydration is served locally
instead of asking the cluster for a per-subscriber snapshot. It is an opt-in deployment option,
orthogonal to `CACHE_TYPE`, that sets `nearCacheEnabled=true` (`NEAR_CACHE_ENABLED`) on both the sse and
the http-writer interfaces:

```bash
make up NEAR_CACHE=true                       # clustered backend + near cache on
make up NEAR_CACHE=true CACHE_TYPE=ephemeral  # ephemeral backend + near cache on
make verify-near                              # prove the near cache actually served a hydration
```

`make verify-near` writes an item via http, primes the sse near cache for that cache
(`POST /api/v1/near/cache/<id>`), waits until it is listed warm with a local item count, asserts the
near-cache metric moved, and reads the snapshot back over an SSE hydrate subscription.

**Confirming it is used.** The sse interface publishes Micrometer metrics on its own `/prometheus`
(port 7072): `aeroncache_near_warm_caches{domain="cache"}` and the `aeroncache_near_hydrations_served_total`
hit counter (a non-zero delta proves a hydration was served from the near cache, not the cluster). The
management API lists what is warm:

```bash
curl -s localhost:7072/api/v1/near/caches | jq .     # warm caches + local item counts
curl -s localhost:7072/prometheus | grep near        # the near-cache gauges/counters
```

## Observability (optional)

Add a **Prometheus + Grafana** stack that scrapes this pattern and ships a Grafana dashboard for it.
Like the near cache, it is an opt-in deployment option rather than a separate flow — the metrics are
already exposed (the pods carry the `prometheus.io/scrape` and `aeroncache.io/app-metrics-scrape`
annotations by default), so turning it on just adds the stack that collects and visualises them:

```bash
make up OBSERVABILITY=true        # deploy the pattern + Prometheus + Grafana
make observability-grafana        # port-forward Grafana -> http://localhost:3000
```

`OBSERVABILITY=true` installs the shared chart (`../../common/observability`) into the namespace and
provisions this pattern's dashboard (`dashboards/sse.json`, Grafana folder **Aeron Cache
Patterns**). It composes with the other options, e.g.
`make up OBSERVABILITY=true CACHE_TYPE=ephemeral`.

The starter dashboard's panels cover scrape health, JVM heap/CPU, per-operation throughput, active subscriptions and the near-cache gauges; specialise `dashboards/sse.json` to taste.
Confirm Prometheus discovered the pods with `make observability-prometheus`
(→ http://localhost:9090/targets).

Add it to, or remove it from, an already-running pattern on its own with `make observability-up` /
`make observability-down`; `make down` removes it too.

## Autoscaling (optional)

Put a **HorizontalPodAutoscaler** on the sse interface — an opt-in deployment option like the near cache
and observability. `AUTOSCALE=true` sets `autoscaling.enabled=true` on the sse interface chart, gives the
pods the CPU/memory **requests** a CPU HPA needs, and (via `make cluster-up`) installs **metrics-server**:

```bash
make up AUTOSCALE=true                        # the sse interface scales between 2 and 5 replicas at 60% CPU
make up AUTOSCALE=true HPA_MIN=2 HPA_MAX=8 HPA_CPU=50   # tunable; composes with OBSERVABILITY/NEAR_CACHE
make up AUTOSCALE=true HPA_MEM=70    # also scale on memory (% of the memory request; the HPA follows whichever metric wants more replicas)
```

SSE is a read-only stream (writes go through the http writer), so there is no `make verify-hpa` helper
here (unlike the http/full-stack patterns). Generate load with concurrent SSE subscribers plus writes via
the http writer, then watch the autoscaler react:

```bash
kubectl get hpa -w -n aeroncache-patterns     # TARGETS crosses 60% -> REPLICAS rises (metrics lag ~15-30s)
```

With `OBSERVABILITY=true` the replica count also shows up on the Grafana dashboard.

> The RAFT cluster / ephemeral **backend** is never autoscaled: its membership is fixed, so scaling it
> would break consensus. `AUTOSCALE` only touches the stateless interface tier.

## Teardown

```bash
make down            # uninstall the interfaces + backend
make cluster-down    # (optional) delete the whole cluster
```

## How it works

- **Four vendored charts** (`charts/VENDOR.lock` pins the upstream commit): the two backends
  (`aeroncache-cluster`, `aeroncache-ephemeral`), `aeroncache-sse`, and `aeroncache-http` (the writer).
- **`CACHE_TYPE` wiring** is applied to **both** interfaces (same `cacheMode` / `clusterAddresses` /
  ephemeral endpoints), so http and sse address the same backend.
- **Verify** uses the shared `common/smoke.sh` in `command` mode with a **second port-forward**
  (the http writer), then runs the SSE round-trip script.

## References

- Vendored from [aeron-cache/k8s/helm](https://github.com/bhf/aeron-cache/tree/main/k8s/helm) (`aeroncache-cluster`, `aeroncache-ephemeral`, `aeroncache-http`, `aeroncache-sse`; pinned SHA in `charts/VENDOR.lock`)
- [SSE OpenAPI](https://github.com/bhf/aeron-cache/blob/main/cache-sse/sse-openapi.yaml)
- Aeron Cache site: https://aeron-cache.pages.dev
