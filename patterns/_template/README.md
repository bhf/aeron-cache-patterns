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

## Observability (optional)

A **Prometheus + Grafana** stack is available to every pattern as an opt-in deployment option (the
charts already expose metrics via pod annotations):

```bash
make up OBSERVABILITY=true     # deploy the pattern + Prometheus + Grafana
make observability-grafana     # port-forward Grafana -> http://localhost:3000
```

`OBSERVABILITY=true` installs the shared `../../common/observability` chart and provisions this
pattern's dashboard from `dashboards/__PATTERN__.json` (create it — a per-pattern starter over the
metrics this pattern exposes; if it is absent the stack still installs, just with no dashboard).
`make down` removes the stack too; `make observability-up` / `observability-down` toggle it on a
running pattern.

## Autoscaling (optional)

If this pattern has a **stateless interface tier** (an http/ws/sse/gateway interface or the Next.js UI),
it can carry a **HorizontalPodAutoscaler** as an opt-in deployment option. Add `$(AUTOSCALE_FLAGS)` to
each interface chart's `helm` install line in the Makefile (never the RAFT cluster / ephemeral / monolith
backend — fixed membership). Then:

```bash
make up AUTOSCALE=true          # interface scales between 2 and 5 replicas at 60% CPU (HPA_MIN/HPA_MAX/HPA_CPU tune it)
```

`AUTOSCALE=true` sets `autoscaling.enabled=true` + CPU/memory requests on the interface, and
`make cluster-up` installs metrics-server. If the interface speaks HTTP REST, set `HPA_LOAD := true`
before including `common/pattern.mk` to offer `make verify-hpa` (a load generator that watches the HPA
scale). Otherwise document how to drive load and `kubectl get hpa -w`. See the http/full-stack patterns.

## Teardown

```bash
make down            # uninstall the pattern (and the observability stack, if installed)
make cluster-down    # (optional) delete the whole cluster
```

## How it works

Notes on the vendored charts, the key values this pattern overrides, and the relevant Aeron
Cache mechanics. Link to the upstream deep dives rather than restating them.

## References

- Vendored from upstream charts: [aeron-cache/k8s/helm](https://github.com/bhf/aeron-cache/tree/main/k8s/helm) (pinned SHA in `charts/VENDOR.lock`)
- Aeron Cache site: https://aeron-cache.pages.dev
