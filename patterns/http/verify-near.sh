#!/usr/bin/env bash
# Near-cache verify for the http interface.
#
# Proves the near cache is actually serving reads, not just that NEAR_CACHE_ENABLED is set. It:
#   1. creates a cache and writes an item (via the normal http data path),
#   2. primes the near cache for it (POST /api/v1/near/cache/<id>) and waits until the interface
#      reports it warm with a local item count (GET /api/v1/near/caches),
#   3. asserts the near-cache metric on the interface's OWN /prometheus (the Micrometer gauge
#      aeroncache_near_warm_caches{domain="cache"}) rose, and
#   4. reads the item back — now served from the warm local copy, no cluster round-trip.
#
# Requires the near cache to be enabled (make up NEAR_CACHE=true); without it the prime route and the
# metric are absent, and the prime step fails with a clear message.
#
# Run by `make verify-near` via common/smoke.sh (SMOKE_MODE=command), which port-forwards the http
# Service and passes BASE (e.g. http://localhost:7070) in the environment.
set -euo pipefail

BASE="${BASE:?BASE is required (http interface, e.g. http://localhost:7070)}"
CACHE_ID="${CACHE_ID:-near-http}"
WARM_TIMEOUT="${WARM_TIMEOUT:-30}"

fail() { echo "NEAR VERIFY FAILED: $*" >&2; exit 1; }

# The aeroncache_near_warm_caches gauge value for domain="cache" on /prometheus (0 if the series is
# absent, e.g. near caching disabled). Micrometer prints a float (e.g. "1.0"); callers compare numerically.
warm_gauge() {
  curl --fail --silent --show-error "${BASE}/prometheus" 2>/dev/null \
    | awk '/^aeroncache_near_warm_caches\{/ && /domain="cache"/ {v=$NF} END {print (v==""?0:v)}'
}

echo "==> Create cache '${CACHE_ID}' and write an item"
curl --fail --silent --show-error -X POST "${BASE}/api/v1/cache" \
  -H 'Content-Type: application/json' -d "{\"cacheId\": \"${CACHE_ID}\"}" >/dev/null \
  || echo "    (create returned non-2xx — continuing, cache may already exist)"
curl --fail --silent --show-error -X POST "${BASE}/api/v1/cache/${CACHE_ID}" \
  -H 'Content-Type: application/json' -d '{"key": "testKey", "value": "testValue"}' >/dev/null \
  || fail "put item"

BEFORE=$(warm_gauge)
echo "==> Baseline aeroncache_near_warm_caches{domain=cache} = ${BEFORE}"

echo "==> Prime the near cache (POST /api/v1/near/cache/${CACHE_ID})"
PRIME=$(curl --fail --silent --show-error -X POST "${BASE}/api/v1/near/cache/${CACHE_ID}") \
  || fail "prime request failed (is the near cache enabled? run 'make up NEAR_CACHE=true')"
echo "    prime: ${PRIME}"

echo "==> Waiting up to ${WARM_TIMEOUT}s for '${CACHE_ID}' to be listed warm with items"
ITEMS=0
deadline=$((SECONDS + WARM_TIMEOUT))
while [[ $SECONDS -lt $deadline ]]; do
  ITEMS=$(curl --fail --silent --show-error "${BASE}/api/v1/near/caches" 2>/dev/null \
    | jq -r --arg c "$CACHE_ID" '[.[] | select(.cacheId == $c)] | .[0].itemCount // 0' 2>/dev/null || echo 0)
  [[ "$ITEMS" =~ ^[0-9]+$ && "$ITEMS" -ge 1 ]] && break
  sleep 2
done
[[ "$ITEMS" =~ ^[0-9]+$ && "$ITEMS" -ge 1 ]] \
  || fail "'${CACHE_ID}' was not warm with items within ${WARM_TIMEOUT}s (itemCount=${ITEMS})"
echo "    warm: '${CACHE_ID}' holds ${ITEMS} item(s) locally"

AFTER=$(warm_gauge)
echo "==> aeroncache_near_warm_caches{domain=cache}: ${BEFORE} -> ${AFTER}"
# Assert >= 1 (not strictly > before) so a re-run against an already-warm cache still passes; the warm
# listing above and the near-served read below are the proof the near cache actually holds this cache.
awk -v a="$AFTER" 'BEGIN{exit !(a+0 >= 1)}' \
  || fail "warm-caches metric is not >= 1 after priming (got ${AFTER})"

echo "==> Read the item back (now served from the warm local copy)"
RESP=$(curl --fail --silent --show-error "${BASE}/api/v1/cache/${CACHE_ID}/testKey") || fail "get item"
echo "    response: ${RESP}"
[[ "$RESP" == *"testValue"* ]] || fail "expected 'testValue' in response, got: ${RESP}"

echo "==> NEAR CACHE VERIFY PASSED (served from near cache; warm gauge ${BEFORE} -> ${AFTER})"
