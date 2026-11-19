# HTTP interface

> A backend plus only the HTTP request/response interface — against a clustered or ephemeral cache.

## Overview

This pattern deploys an Aeron Cache **backend** and the **HTTP interface** (`aeroncache-http`) in
front of it — nothing else. HTTP is the request/response surface: create caches, put/get items,
counters, TTL, bulk operations, snapshot-and-purge. It is the simplest interface pattern and the
building block the other interface patterns follow.

One `CACHE_TYPE` variable picks the backend:

- **`clustered`** (default) — a 3-node RAFT cluster (`aeroncache-cluster`). Replicated and highly
  available; the interface addresses all three nodes.
- **`ephemeral`** — a single-node SINGLE-mode cache (`aeroncache-ephemeral`). One pod, no
  replication; the interface points at the one node's response-channel endpoints.

Reach for this when you want the HTTP API and nothing more — a REST integration target, a smoke
environment, or the base you extend with ws/sse/UI (see the full-stack pattern).

## Architecture

```mermaid
flowchart LR
  client([Client]) -->|"HTTP :7070"| http["aeroncache-http"]
  http ==>|Aeron| backend[("Backend<br/>clustered: RAFT cluster-0 · -1 · -2<br/>ephemeral: SINGLE ephemeral-0")]
```

Both backends co-locate a clustertools sidecar (media-driver counters on 7080). The HTTP Service
is `aeroncache-http:7070` in either case.

## Prerequisites

- A local Kubernetes cluster via **minikube** (the default) — see the [repo README](../../README.md).
- `kubectl`, `helm`, `curl`, `jq`. Run `make doctor` from the repo root.
- The clustered variant runs 4 pods (3 cluster nodes + http); ephemeral runs 2 (1 node + http).

## Run

From this directory:

```bash
make up                       # clustered backend + http interface
# or
make up CACHE_TYPE=ephemeral  # single-node ephemeral backend + http interface

make verify                   # smoke test: create a cache, put an item, read it back
```

To use kind instead (as CI does): add `CLUSTER=kind`.

## Verify

`make verify` port-forwards `svc/aeroncache-http:7070` and runs a create/put/get round-trip against
either backend. A healthy deployment ends with `SMOKE PASSED`.

## Teardown

```bash
make down            # uninstall the interface + backend
make cluster-down    # (optional) delete the whole cluster
```

## How it works

- **Three vendored charts** (`charts/VENDOR.lock` pins the upstream commit): `aeroncache-cluster`
  and `aeroncache-ephemeral` are the two backends (both run the `aeroncache-cluster` image plus the
  `aeroncache-http-clustertools` sidecar); `aeroncache-http` is the interface.
- **`CACHE_TYPE` wiring (in the Makefile).** `clustered` installs `aeroncache-cluster` and leaves
  the interface on its defaults (cacheMode `RAFT`, `clusterAddresses` templated to the namespace).
  `ephemeral` installs `aeroncache-ephemeral` in SINGLE mode and sets the interface's
  `cacheMode=SINGLE`, `clusterAddresses`, and the `ephemeralRequestEndpoint` /
  `ephemeralResponseControlEndpoint` (ports 8075/8076) at the single node.
- **Values overlay.** `values/aeroncache-http.yaml` sets a `ClusterIP` Service so `make verify`
  reaches the interface via port-forward (the chart defaults to `LoadBalancer`).

## References

- Vendored from [aeron-cache/k8s/helm](https://github.com/bhf/aeron-cache/tree/main/k8s/helm) (`aeroncache-cluster`, `aeroncache-ephemeral`, `aeroncache-http`; pinned SHA in `charts/VENDOR.lock`)
- Aeron Cache site: https://aeron-cache.pages.dev
