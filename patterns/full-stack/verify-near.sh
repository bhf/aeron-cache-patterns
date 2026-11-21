#!/usr/bin/env bash
# Near-cache verify for the full-stack pattern.
#
# The full stack enables the near cache on all three web interfaces (http, ws, sse), each keeping its
# OWN independent near cache. This check proves all three actually warm: it creates a cache and writes
# an item once (via http), then for each interface it primes that interface's near cache
# (POST /api/v1/near/cache/<id>), waits until the interface lists it warm with a local item count, and
# asserts the aeroncache_near_warm_caches{domain="cache"} gauge on that interface's own /prometheus rose.
#
# Priming and the metric are plain HTTP on each interface's port, so one curl-based check covers all
# three. common/smoke.sh already port-forwards the http interface (BASE) and the UI; this script opens
# its own forwards to the ws and sse Services (not otherwise forwarded for this pattern).
#
# Requires the near cache to be enabled (make up NEAR_CACHE=true).
#
# Run by `make verify-near` via common/smoke.sh (SMOKE_MODE=command), which passes BASE (the http
# interface, e.g. http://localhost:7070) in the environment.
set -euo pipefail

NAMESPACE="${NAMESPACE:-aeroncache-patterns}"
BASE="${BASE:?BASE is required (http interface, e.g. http://localhost:7070)}"
CACHE_ID="${CACHE_ID:-near-fullstack}"
WARM_TIMEOUT="${WARM_TIMEOUT:-30}"

# Localhost ports this script binds for the ws/sse forwards (offset to avoid clashing with the http
# forward smoke.sh already holds).
WS_LOCAL="${WS_LOCAL:-17071}"
SSE_LOCAL="${SSE_LOCAL:-17072}"

fail() { echo "NEAR VERIFY FAILED: $*" >&2; exit 1; }

PF_PIDS=()
cleanup() { for p in "${PF_PIDS[@]:-}"; do kill "$p" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT

# aeroncache_near_warm_caches gauge value for domain="cache" on the given interface's /prometheus.
warm_gauge() {
  curl --fail --silent --show-error "$1/prometheus" 2>/dev/null \
    | awk '/^aeroncache_near_warm_caches\{/ && /domain="cache"/ {v=$NF} END {print (v==""?0:v)}'
}

# check_interface <label> <base-url>: prime the near cache on that interface, wait until warm, and
# assert its warm-caches gauge rose.
check_interface() {
  local label="$1" base="$2" before after items deadline
  before=$(warm_gauge "$base")
  echo "   [$label] baseline aeroncache_near_warm_caches{domain=cache} = ${before}"

  echo "   [$label] prime (POST ${base}/api/v1/near/cache/${CACHE_ID})"
  curl --fail --silent --show-error -X POST "${base}/api/v1/near/cache/${CACHE_ID}" >/dev/null \
    || fail "[$label] prime request failed (is the near cache enabled? run 'make up NEAR_CACHE=true')"

  items=0
  deadline=$((SECONDS + WARM_TIMEOUT))
  while [[ $SECONDS -lt $deadline ]]; do
    items=$(curl --fail --silent --show-error "${base}/api/v1/near/caches" 2>/dev/null \
      | jq -r --arg c "$CACHE_ID" '[.[] | select(.cacheId == $c)] | .[0].itemCount // 0' 2>/dev/null || echo 0)
    [[ "$items" =~ ^[0-9]+$ && "$items" -ge 1 ]] && break
    sleep 2
  done
  [[ "$items" =~ ^[0-9]+$ && "$items" -ge 1 ]] \
    || fail "[$label] '${CACHE_ID}' was not warm with items within ${WARM_TIMEOUT}s (itemCount=${items})"

  after=$(warm_gauge "$base")
  awk -v a="$after" -v b="$before" 'BEGIN{exit !(a+0 > b+0)}' \
    || fail "[$label] warm-caches metric did not increase (${before} -> ${after})"
  echo "   [$label] OK — warm with ${items} item(s); gauge ${before} -> ${after}"
}

echo "==> Create cache '${CACHE_ID}' and write an item (via http)"
curl --fail --silent --show-error -X POST "${BASE}/api/v1/cache" \
  -H 'Content-Type: application/json' -d "{\"cacheId\": \"${CACHE_ID}\"}" >/dev/null \
  || echo "    (create returned non-2xx — continuing, cache may already exist)"
curl --fail --silent --show-error -X POST "${BASE}/api/v1/cache/${CACHE_ID}" \
  -H 'Content-Type: application/json' -d '{"key": "testKey", "value": "testValue"}' >/dev/null \
  || fail "put item"

echo "==> Port-forwarding the ws and sse interfaces for their near-cache checks"
kubectl port-forward -n "$NAMESPACE" svc/aeroncache-ws "${WS_LOCAL}:7071" >/dev/null 2>&1 &
PF_PIDS+=($!)
kubectl port-forward -n "$NAMESPACE" svc/aeroncache-sse "${SSE_LOCAL}:7072" >/dev/null 2>&1 &
PF_PIDS+=($!)
sleep 3

echo "==> Verifying each interface's near cache warms independently"
check_interface http "$BASE"
check_interface ws   "http://localhost:${WS_LOCAL}"
check_interface sse  "http://localhost:${SSE_LOCAL}"

echo "==> Read the item back from the http near cache (served from the warm local copy)"
RESP=$(curl --fail --silent --show-error "${BASE}/api/v1/cache/${CACHE_ID}/testKey") || fail "get item"
[[ "$RESP" == *"testValue"* ]] || fail "expected 'testValue' in response, got: ${RESP}"

echo "==> NEAR CACHE VERIFY PASSED (http, ws and sse near caches all warm)"
