#!/usr/bin/env bash
# Near-cache verify for the aeron transport gateway.
#
# The gateway speaks SBE-over-Aeron (no HTTP data path), but it exposes the same near cache management
# API as the web gateways on its HTTP health server (7073), and its near cache metrics as Aeron
# media-driver counters (type 2100) that the co-located clustertools sidecar publishes in Prometheus
# format on 7080. This check:
#   1. primes the gateway's near cache for a cache id (POST :7073/api/v1/near/cache/<id>), which starts
#      the internal warming subscription and adds the cache to the gateway's warm set, and
#   2. asserts the aeron_gateway_near_warm_caches{domain="cache"} gauge on the clustertools /prometheus
#      (7080) rose — proving the near cache subsystem is active and wired through to the metrics.
#
# The gateway's data path (a real Aeron round-trip via the aeron-sample Job) is covered by `make
# verify`; this check focuses on the near cache. Requires the near cache to be enabled
# (make up NEAR_CACHE=true); without it the prime route and the metric are absent.
#
# Run by `make verify-near` via common/smoke.sh (SMOKE_MODE=command), which has already port-forwarded
# the gateway health server and passes BASE (e.g. http://localhost:7073) in the environment. The
# clustertools endpoint (7080) is not exposed via the Service, so we port-forward straight to the pod.
set -euo pipefail

NAMESPACE="${NAMESPACE:-aeroncache-patterns}"
BASE="${BASE:?BASE is required (gateway health server, e.g. http://localhost:7073)}"
CACHE_ID="${CACHE_ID:-near-gateway}"
CT_PORT="${CT_PORT:-7080}"
LOCAL_CT="${LOCAL_CT:-17080}"
WARM_TIMEOUT="${WARM_TIMEOUT:-45}"

fail() { echo "NEAR VERIFY FAILED: $*" >&2; exit 1; }

# The gateway's "near warm caches for the cache domain" counter value on the clustertools /prometheus
# (0 if absent). Matches both the parsed family the newer clustertools emits
# (aeron_gateway_near_warm_caches{domain="cache"}) and the raw Aeron counter the pinned image emits
# (aeron_counter{...,label="AeronCache-Gateway-NearWarmCaches-cache-<node>"}).
warm_gauge() {
  curl --fail --silent --show-error "http://localhost:${LOCAL_CT}/prometheus" 2>/dev/null \
    | awk '/aeron_gateway_near_warm_caches\{/ && /domain="cache"/ {v=$NF}
           /AeronCache-Gateway-NearWarmCaches-cache-/ {v=$NF}
           END {print (v==""?0:v)}'
}

POD=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/name=aeroncache-gateway \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -n "$POD" ]] || fail "no gateway pod found (label app.kubernetes.io/name=aeroncache-gateway)"

echo "==> Port-forwarding clustertools metrics on ${POD}:${CT_PORT}"
kubectl port-forward -n "$NAMESPACE" "pod/${POD}" "${LOCAL_CT}:${CT_PORT}" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" >/dev/null 2>&1 || true' EXIT
sleep 3

BEFORE=$(warm_gauge)
echo "==> Baseline aeron_gateway_near_warm_caches{domain=cache} = ${BEFORE}"

echo "==> Prime the gateway near cache (POST ${BASE}/api/v1/near/cache/${CACHE_ID})"
PRIME=$(curl --fail --silent --show-error -X POST "${BASE}/api/v1/near/cache/${CACHE_ID}") \
  || fail "prime request failed (is the near cache enabled? run 'make up NEAR_CACHE=true')"
echo "    prime: ${PRIME}"

echo "==> Waiting up to ${WARM_TIMEOUT}s for the near warm-caches counter to reach >= 1"
AFTER="$BEFORE"
deadline=$((SECONDS + WARM_TIMEOUT))
while [[ $SECONDS -lt $deadline ]]; do
  AFTER=$(warm_gauge)
  awk -v a="$AFTER" 'BEGIN{exit !(a+0 >= 1)}' && break
  sleep 3
done

echo "==> near warm-caches (cache domain): ${BEFORE} -> ${AFTER}"
# Assert >= 1 (not strictly > before) so a re-run against an already-warm gateway still passes; a SUCCESS
# prime plus a warm counter of >= 1 is the proof the near cache subsystem is active and metered.
awk -v a="$AFTER" 'BEGIN{exit !(a+0 >= 1)}' \
  || fail "near warm-caches counter is not >= 1 within ${WARM_TIMEOUT}s (got ${AFTER})"

echo "==> NEAR CACHE VERIFY PASSED (gateway near cache warm; gauge ${BEFORE} -> ${AFTER})"
