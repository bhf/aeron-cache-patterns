# __PATTERN__

> One-sentence summary of the pattern.

## Overview

What this pattern deploys and **when to reach for it** — the scenario it models, and how it
differs from the neighbouring patterns. Keep this grounded: a reader should know within a
paragraph whether this is the pattern they want.

## Architecture

The topology this pattern stands up — pods, Services, cluster shape — and how traffic flows.
A short ASCII diagram usually earns its place:

```
client ──HTTP──▶ Service ──▶ pod(s)
```

## Prerequisites

- A local Kubernetes cluster via **minikube** (the default) — see the [repo README](../../README.md).
- `kubectl`, `helm`, `curl`, `jq`. Run `make doctor` from the repo root to check.
- Pattern-specific prerequisites, if any (also listed in `meta.yaml`).

## Run

From this directory:

```bash
make up        # start minikube, deploy the pattern, wait for pods to be Ready
make verify    # smoke test: create a cache, put an item, read it back
```

To use kind instead (as CI does): `make up CLUSTER=kind`.

## Verify

`make verify` port-forwards the HTTP interface and runs a create/put/get round-trip against
the live deployment. A healthy pattern ends with `SMOKE PASSED`.

## Teardown

```bash
make down            # uninstall the pattern
make cluster-down    # (optional) delete the whole cluster
```

## How it works

Notes on the vendored charts, the key values this pattern overrides, and the relevant Aeron
Cache mechanics. Link to the upstream deep dives rather than restating them.

## References

- Vendored from upstream charts: [aeron-cache/k8s/helm](https://github.com/bhf/aeron-cache/tree/main/k8s/helm) (pinned SHA in `charts/VENDOR.lock`)
- Aeron Cache docs: https://aeron-cache.pages.dev
