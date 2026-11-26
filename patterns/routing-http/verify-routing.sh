#!/usr/bin/env bash
# Prove routing by cache id for the routing-http pattern.
#
# Two independent caches run behind one Ingress: "alpha" is owned by instance 0 (aeroncache-http-0),
# "beta" by instance 1 (aeroncache-http-1). This script asserts three things:
#   1. Routed round-trip — writing and reading each cache THROUGH the ingress works and returns the
#      right value (so the id in the path selected a working gateway).
#   2. Correct landing — reading each cache DIRECTLY from its owning gateway returns the value.
#   3. Isolation — the other gateway never received it (the value is absent there). This is what rules
#      out round-robin / a shared backend: the ingress routed by the cache id, not by chance.
#
# Run by `make verify` via common/smoke.sh (SMOKE_MODE=command), which first health-gates
# svc/aeroncache-http-0. This script does its own port-forwards: the ingress controller (the routed
# front door) and each gateway directly (for the landing/isolation checks).
set -euo pipefail

NAMESPACE="${NAMESPACE:-aeroncache-patterns}"

# Ingress controller (the front door) and the two gateways, each on a distinct local port.
ING_LOCAL=18080
GW0_LOCAL=17070
GW1_LOCAL=17071
ING="http://localhost:${ING_LOCAL}"
GW0="http://localhost:${GW0_LOCAL}"
GW1="http://localhost:${GW1_LOCAL}"

fail() { echo "ROUTING VERIFY FAILED: $*" >&2; exit 1; }

PF_PIDS=()
cleanup() { for p in "${PF_PIDS[@]:-}"; do kill "$p" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT

pf() { # pf <ns> <svc> <local:remote>
  kubectl port-forward -n "$1" "$2" "$3" >/dev/null 2>&1 &
  PF_PIDS+=($!)
}

echo "==> Port-forwarding the ingress controller and both gateways"
pf ingress-nginx svc/ingress-nginx-controller "${ING_LOCAL}:80"
pf "$NAMESPACE"   svc/aeroncache-http-0        "${GW0_LOCAL}:7070"
pf "$NAMESPACE"   svc/aeroncache-http-1        "${GW1_LOCAL}:7070"
sleep 4

# --- 1. Routed round-trip through the ingress -------------------------------
# curl --retry here also gives the ingress/backends a moment to be reachable.
route_write() { # route_write <base> <cacheId> <value>
  curl --fail --silent --show-error --retry 10 --retry-delay 3 --retry-connrefused \
    -X PUT "$1/api/v1/cache/$2" >/dev/null || fail "create '$2' via $1"
  curl --fail --silent --show-error -X POST "$1/api/v1/cache/$2" \
    -H 'Content-Type: application/json' -d "{\"key\":\"testKey\",\"value\":\"$3\"}" >/dev/null \
    || fail "put '$2' via $1"
}
get() { # get <base> <cacheId> -> echoes body (no --fail, so a 404 is just empty-ish)
  curl --silent --show-error -X GET "$1/api/v1/cache/$2/testKey" 2>/dev/null || true
}

echo "==> [1] Write alpha and beta THROUGH the ingress"
route_write "$ING" alpha alpha-value
route_write "$ING" beta  beta-value

echo "==> [1] Read them back through the ingress"
r=$(get "$ING" alpha); echo "    ingress alpha -> $r"
[[ "$r" == *alpha-value* ]] || fail "routed read of 'alpha' did not return alpha-value (got: $r)"
r=$(get "$ING" beta);  echo "    ingress beta  -> $r"
[[ "$r" == *beta-value* ]]  || fail "routed read of 'beta' did not return beta-value (got: $r)"

# --- 2. Correct landing (read each directly from its owner) -----------------
echo "==> [2] alpha lands on instance 0, beta on instance 1 (direct reads)"
r=$(get "$GW0" alpha); [[ "$r" == *alpha-value* ]] || fail "alpha not found on its owner http-0 (got: $r)"
r=$(get "$GW1" beta);  [[ "$r" == *beta-value* ]]  || fail "beta not found on its owner http-1 (got: $r)"

# --- 3. Isolation (the other gateway never received it) ---------------------
echo "==> [3] Isolation: alpha absent on instance 1, beta absent on instance 0"
r=$(get "$GW1" alpha)
[[ "$r" != *alpha-value* ]] || fail "ISOLATION BROKEN: 'alpha' is present on http-1 — routing is not by cache id (got: $r)"
r=$(get "$GW0" beta)
[[ "$r" != *beta-value* ]]  || fail "ISOLATION BROKEN: 'beta' is present on http-0 — routing is not by cache id (got: $r)"

echo "==> ROUTING VERIFY PASSED (alpha->instance 0, beta->instance 1, isolated)"
