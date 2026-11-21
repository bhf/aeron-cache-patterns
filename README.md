# aeron-cache-patterns

![img.png](https://raw.githubusercontent.com/bhf/aeron-cache/refs/heads/main/docs/images/header.png)

[![Monolith](https://github.com/bhf/aeron-cache-patterns/actions/workflows/monolith.yml/badge.svg)](https://github.com/bhf/aeron-cache-patterns/actions/workflows/monolith.yml)
[![Monolith + UI](https://github.com/bhf/aeron-cache-patterns/actions/workflows/monolith-ui.yml/badge.svg)](https://github.com/bhf/aeron-cache-patterns/actions/workflows/monolith-ui.yml)
[![HTTP interface](https://github.com/bhf/aeron-cache-patterns/actions/workflows/http.yml/badge.svg)](https://github.com/bhf/aeron-cache-patterns/actions/workflows/http.yml)
[![WebSocket interface](https://github.com/bhf/aeron-cache-patterns/actions/workflows/ws.yml/badge.svg)](https://github.com/bhf/aeron-cache-patterns/actions/workflows/ws.yml)
[![SSE interface](https://github.com/bhf/aeron-cache-patterns/actions/workflows/sse.yml/badge.svg)](https://github.com/bhf/aeron-cache-patterns/actions/workflows/sse.yml)
[![Aeron transport gateway](https://github.com/bhf/aeron-cache-patterns/actions/workflows/aeron-gateway.yml/badge.svg)](https://github.com/bhf/aeron-cache-patterns/actions/workflows/aeron-gateway.yml)
[![Full stack](https://github.com/bhf/aeron-cache-patterns/actions/workflows/full-stack.yml/badge.svg)](https://github.com/bhf/aeron-cache-patterns/actions/workflows/full-stack.yml)
[![Docs build](https://github.com/bhf/aeron-cache-patterns/actions/workflows/docs-ci.yml/badge.svg)](https://github.com/bhf/aeron-cache-patterns/actions/workflows/docs-ci.yml)

Patterns and deployments for [Aeron Cache](https://github.com/bhf/aeron-cache).

Each **pattern** is a self-contained, easy-to-spin-up Kubernetes deployment that demonstrates
one way of running Aeron Cache — a monolith, a clustered backend with gateways, autoscaling,
near caching, service mesh, GitOps, and so on. Every pattern carries its own vendored Helm
charts, a one-command run (`make up`), a smoke test (`make verify`), co-located docs, and its
own CI.

Patterns pull the **public** released images from `ghcr.io/bhf/aeroncache-*`, so this repo
needs no Java toolchain and builds nothing — your cluster pulls the images directly.

## Quick start

```bash
make doctor                 # check you have minikube, kubectl, helm, curl, jq
make list                   # see available patterns
make up     PATTERN=monolith
make verify PATTERN=monolith
make down   PATTERN=monolith
```

Or `cd patterns/monolith && make up && make verify`.

Local runs use **minikube** by default. CI uses **kind**; you can too with `make up CLUSTER=kind`.

## Common options

Two cross-cutting variables compose with the interface patterns (http, ws, sse, aeron-gateway,
full-stack). Both are deployment options on the normal `make up` lifecycle — there is no separate
target for either, so one convention covers every combination:

- **`CACHE_TYPE`** — `clustered` (default, 3-node RAFT) or `ephemeral` (single SINGLE-mode node).
- **`NEAR_CACHE`** — `false` (default) or `true` to enable the server-side **near cache** on the
  pattern's interface(s): a warm local copy that serves reads/hydration instead of round-tripping to
  the cluster.

They are orthogonal, so all four combinations are just `make up` plus the variables:

| | No near cache | Near cache |
|---|---|---|
| **Clustered** (default) | `make up` | `make up NEAR_CACHE=true` |
| **Ephemeral** | `make up CACHE_TYPE=ephemeral` | `make up NEAR_CACHE=true CACHE_TYPE=ephemeral` |

When near caching is on, `make verify-near` proves it actually served a read (via each interface's
near-cache metrics). See each pattern's **Near cache (optional)** section.

## Repository layout

```
versions.env          # the single pinned Aeron Cache release every pattern + CI uses
Makefile              # top-level: list / delegate up|down|verify to a pattern / doctor
common/               # shared pieces every pattern reuses
  ghcr.mk             #   helm --set flags pointing images at the pinned GHCR release
  pattern.mk          #   shared make targets (up/down/verify/wait/status/logs/...)
  cluster.sh          #   cluster lifecycle: minikube (local) or kind (CI)
  smoke.sh            #   reusable create/put/get smoke test
patterns/
  _template/          # scaffold for a new pattern (see scripts/new-pattern.sh)
  <pattern>/
    README.md         #   canonical docs (also rendered by the docs-site)
    meta.yaml         #   structured metadata for the docs-site index
    Makefile          #   sets variables + defines deploy/undeploy; includes common/pattern.mk
    values/           #   per-chart values overlays
    charts/           #   vendored upstream charts + VENDOR.lock (pinned provenance)
docs-site/            # Astro + Tailwind docs site (run locally; deploy later)
scripts/
  doctor.sh           # tooling check
  sync-charts.sh      # vendor upstream charts into a pattern (records provenance)
  new-pattern.sh      # scaffold a new pattern from _template
.github/workflows/
  _pattern-ci.yml     # reusable CI (kind + deploy + wait + smoke); per-pattern callers call it
```

## How a pattern works

1. **Charts are vendored, not referenced.** `scripts/sync-charts.sh <pattern> <chart>...` copies
   exactly the charts a pattern deploys into `patterns/<pattern>/charts/` and records the upstream
   commit in `charts/VENDOR.lock`. The pattern folder is fully standalone.
2. **Images are pinned in one place.** `versions.env` sets the release; `common/ghcr.mk` turns it
   into the `--set image.repository/tag/pullPolicy` flags the chart install uses. Bump the release
   in one line.
3. **The same smoke test everywhere.** `common/smoke.sh` runs the create/put/get round-trip both
   for `make verify` locally and in CI, so "green" means the same thing in both places.

## Adding a pattern

```bash
scripts/new-pattern.sh my-pattern
scripts/sync-charts.sh my-pattern aeroncache-monolith   # the charts it deploys
# edit patterns/my-pattern/{meta.yaml,README.md,Makefile,values/}
# add .github/workflows/my-pattern.yml (copy an existing caller; set the paths filter)
```

## Docs site

`docs-site/` is an Astro + Tailwind site (same design system as
[aeron-cache-site](https://github.com/bhf/aeron-cache-site)) that renders each pattern's
`README.md` + `meta.yaml`. Run it locally:

```bash
cd docs-site && npm install && npm run dev
```

It is not deployed yet — Cloudflare Pages deployment will come later.
