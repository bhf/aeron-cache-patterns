# Full stack (http + ws + sse + UI)

> The complete web stack — a backend plus all three web interfaces and the Next.js UI.

## Overview

This pattern deploys an Aeron Cache **backend** together with the **http**, **ws** and **sse**
interfaces and the **Next.js UI** (`aeroncache-ui-nextjs`) — the full front-to-back web stack, and
the only pattern that includes the UI (which consumes http + ws + sse together).

`CACHE_TYPE` picks the backend — **`clustered`** (3-node RAFT, default) or **`ephemeral`**
(single-node SINGLE). All three interfaces are wired to the chosen backend; the UI addresses the
interfaces by Service name / localhost and is unaffected by the backend choice.

Reach for this when you want the whole thing running — a demo, a manual test environment, or a look
at the UI driving the cache.

## Architecture

```
  browser ──▶ aeroncache-ui-nextjs (3000) ──(server-side)── http ─┐
     │                                                            │
     ├── ws  (browser, localhost:7071) ─▶ aeroncache-ws  (7071) ──┤
     ├── sse (browser, localhost:7072) ─▶ aeroncache-sse (7072) ──┼─Aeron─▶ backend
     └── http proxied by the UI server ─▶ aeroncache-http (7070) ─┘            (clustered | ephemeral)
```

The UI server proxies the cache **HTTP API** over the in-cluster Service DNS (`aeroncache-http`),
while the **browser opens ws/sse directly on localhost** via port-forward (these are the UI chart's
default endpoints — intentionally kept).

## Prerequisites

- A local Kubernetes cluster via **minikube** (the default) — see the [repo README](../../README.md).
- `kubectl`, `helm`, `curl`, `jq`. Run `make doctor`.
- Clustered runs 7 pods (3 cluster nodes + http + ws + sse + ui); ephemeral runs 5. Give the cluster
  a little headroom (a few GB) — this is the heaviest pattern.

## Run

```bash
make up                       # clustered backend + http/ws/sse + UI
# or
make up CACHE_TYPE=ephemeral  # single-node ephemeral backend + http/ws/sse + UI

make verify                   # http round-trip + UI readiness
```

To use kind instead (as CI does): add `CLUSTER=kind`.

### Open the UI

Port-forward the UI plus the ws/sse interfaces the browser connects to:

```bash
kubectl port-forward -n aeroncache-patterns svc/aeroncache-ui-nextjs 3000:3000 &
kubectl port-forward -n aeroncache-patterns svc/aeroncache-ws 7071:7071 &
kubectl port-forward -n aeroncache-patterns svc/aeroncache-sse 7072:7072 &
# then open http://localhost:3000
```

## Verify

`make verify` ([`verify-fullstack.sh`](verify-fullstack.sh)) port-forwards the http interface (7070)
and the UI (3000), checks the http interface's liveness/readiness, then:

1. runs a create/put/get round-trip against **http** (asserts the value), and
2. checks the **UI** is serving (`GET /` returns 200).

A healthy deployment ends with `FULL-STACK VERIFY PASSED` then `SMOKE PASSED`.

## Teardown

```bash
make down            # uninstall the UI + interfaces + backend
make cluster-down    # (optional) delete the whole cluster
```

## How it works

- **Six vendored charts** (`charts/VENDOR.lock` pins the upstream commit): the two backends
  (`aeroncache-cluster`, `aeroncache-ephemeral`), `aeroncache-http`, `aeroncache-ws`,
  `aeroncache-sse`, and `aeroncache-ui-nextjs`.
- **`CACHE_TYPE` wiring** is applied to the http/ws/sse interfaces (same `cacheMode` /
  `clusterAddresses` / ephemeral endpoints), so all three address the same backend.
- **UI wiring**: the UI image on GHCR is `aeroncache-ui` (the local build is `aeroncache-ui-nextjs`);
  the Makefile points the image there and sets `namespace` so the UI's ConfigMap lands in this
  pattern's namespace. The endpoint defaults are kept (see Architecture).
- **Verify** uses `common/smoke.sh` in `command` mode with a second port-forward (the UI), running
  the http round-trip plus the UI readiness check.

## References

- Vendored from [aeron-cache/k8s/helm](https://github.com/bhf/aeron-cache/tree/main/k8s/helm) (`aeroncache-cluster`, `aeroncache-ephemeral`, `aeroncache-http`, `aeroncache-ws`, `aeroncache-sse`, `aeroncache-ui-nextjs`; pinned SHA in `charts/VENDOR.lock`)
- Aeron Cache site: https://aeron-cache.pages.dev
