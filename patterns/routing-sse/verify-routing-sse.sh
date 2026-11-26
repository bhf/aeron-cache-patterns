#!/usr/bin/env bash
# Prove routing by cache id for the routing-sse pattern (streaming, unidirectional).
#
# "alpha" is owned by instance 0 (aeroncache-sse-0 + aeroncache-http-0), "beta" by instance 1. SSE is
# read-only, so writes go through the per-instance http writer; both the write and the SSE read are
# routed by the cache id in the path. Asserts:
#   1. Routed round-trip — write each cache via the ingress (http write route), then read it back over
#      a routed SSE hydrate subscription; the value streams through.
#   2. Correct landing — a direct SSE hydrate on the owning sse gateway returns the value.
#   3. Isolation — a direct SSE hydrate on the OTHER sse gateway does not (the value never reached that
#      backend). This proves the ingress routed by cache id, not round-robin.
#
# Run by `make verify` via common/smoke.sh (SMOKE_MODE=command), which first health-gates
# svc/aeroncache-http-0. This script does its own port-forwards.
set -euo pipefail

NAMESPACE="${NAMESPACE:-aeroncache-patterns}"

ING_LOCAL=18080     # ingress controller (front door): http writes + sse reads, both routed by id
SSE0_LOCAL=17072    # sse reader, instance 0 (direct)
SSE1_LOCAL=17073    # sse reader, instance 1 (direct)
ING="http://localhost:${ING_LOCAL}"
SSE0="http://localhost:${SSE0_LOCAL}"
SSE1="http://localhost:${SSE1_LOCAL}"

fail() { echo "ROUTING VERIFY FAILED: $*" >&2; exit 1; }

PF_PIDS=()
cleanup() { for p in "${PF_PIDS[@]:-}"; do kill "$p" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT

pf() { kubectl port-forward -n "$1" "$2" "$3" >/dev/null 2>&1 & PF_PIDS+=($!); }

echo "==> Port-forwarding the ingress controller and both sse gateways"
pf ingress-nginx svc/ingress-nginx-controller "${ING_LOCAL}:80"
pf "$NAMESPACE"  svc/aeroncache-sse-0          "${SSE0_LOCAL}:7072"
pf "$NAMESPACE"  svc/aeroncache-sse-1          "${SSE1_LOCAL}:7072"
sleep 4

# Write a cache via the ingress (routed to the http writer that owns it). --retry also waits for
# ingress/backends to be reachable.
route_write() { # route_write <cacheId> <value>
  curl --fail --silent --show-error --retry 10 --retry-delay 3 --retry-connrefused \
    -X PUT "${ING}/api/v1/cache/$1" >/dev/null || fail "create '$1' via ingress"
  curl --fail --silent --show-error -X POST "${ING}/api/v1/cache/$1" \
    -H 'Content-Type: application/json' -d "{\"key\":\"testKey\",\"value\":\"$2\"}" >/dev/null \
    || fail "put '$1' via ingress"
}
# Read a cache's hydrate snapshot over SSE. -N/--no-buffer stream it; --max-time bounds the read.
sse_hydrate() { # sse_hydrate <base> <cacheId> -> echoes the stream
  curl --silent --no-buffer --max-time 8 "$1/api/sse/v1/cache/hydrate/$2" 2>/dev/null || true
}

echo "==> [1] Write alpha and beta THROUGH the ingress (http write route)"
route_write alpha alpha-value
route_write beta  beta-value

echo "==> [1] Read them back over a ROUTED SSE hydrate subscription"
s=$(sse_hydrate "$ING" alpha); echo "    ingress sse alpha -> $(printf '%s' "$s" | tr '\n' ' ' | head -c 120)"
printf '%s' "$s" | grep -q alpha-value || fail "routed SSE read of 'alpha' did not stream alpha-value"
s=$(sse_hydrate "$ING" beta);  echo "    ingress sse beta  -> $(printf '%s' "$s" | tr '\n' ' ' | head -c 120)"
printf '%s' "$s" | grep -q beta-value  || fail "routed SSE read of 'beta' did not stream beta-value"

echo "==> [2] alpha hydrates from sse-0, beta from sse-1 (direct)"
printf '%s' "$(sse_hydrate "$SSE0" alpha)" | grep -q alpha-value || fail "alpha not on its owner sse-0"
printf '%s' "$(sse_hydrate "$SSE1" beta)"  | grep -q beta-value  || fail "beta not on its owner sse-1"

echo "==> [3] Isolation: alpha absent on sse-1, beta absent on sse-0"
printf '%s' "$(sse_hydrate "$SSE1" alpha)" | grep -q alpha-value \
  && fail "ISOLATION BROKEN: 'alpha' hydrated from sse-1 — routing is not by cache id" || true
printf '%s' "$(sse_hydrate "$SSE0" beta)"  | grep -q beta-value \
  && fail "ISOLATION BROKEN: 'beta' hydrated from sse-0 — routing is not by cache id" || true

echo "==> ROUTING VERIFY PASSED (alpha->instance 0, beta->instance 1, isolated)"
