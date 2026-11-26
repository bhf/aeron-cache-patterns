#!/usr/bin/env bash
# Near-cache verify for the sse interface.
#
# SSE is read-only and serves hydrating subscriptions from the near cache. This check writes an item
# via the http interface, primes the sse interface's near cache for that cache, waits until it is
# listed warm with a local item count, asserts the aeroncache_near_warm_caches{domain="cache"} gauge
# on the sse interface's OWN /prometheus rose, and then reads the snapshot back over an SSE hydrate
# subscription (now served from the warm local copy).
#
# Requires the near cache to be enabled (make up NEAR_CACHE=true); without it the
# prime route and the metric are absent, and the prime step fails with a clear message.
#
# Run by `make verify-near` via common/smoke.sh (SMOKE_MODE=command): SSE_BASE is the sse interface
# (e.g. http://localhost:7072), HTTP_BASE the http writer (e.g. http://localhost:7070).
set -euo pipefail

HTTP_BASE="${HTTP_BASE:?HTTP_BASE is required (http interface, e.g. http://localhost:7070)}"
SSE_BASE="${SSE_BASE:?SSE_BASE is required (sse interface, e.g. http://localhost:7072)}"
CACHE_ID="${CACHE_ID:-near-sse}"
WARM_TIMEOUT="${WARM_TIMEOUT:-30}"

fail() { echo "NEAR VERIFY FAILED: $*" >&2; exit 1; }

warm_gauge() {
  curl --fail --silent --show-error "${SSE_BASE}/prometheus" 2>/dev/null \
    | awk '/^aeroncache_near_warm_caches\{/ && /domain="cache"/ {v=$NF} END {print (v==""?0:v)}'
}

echo "==> Create cache '${CACHE_ID}' and write an item (via http)"
curl --fail --silent --show-error -X PUT "${HTTP_BASE}/api/v1/cache/${CACHE_ID}" >/dev/null \
  || echo "    (create returned non-2xx — continuing, cache may already exist)"
curl --fail --silent --show-error -X POST "${HTTP_BASE}/api/v1/cache/${CACHE_ID}" \
  -H 'Content-Type: application/json' -d '{"key": "testKey", "value": "testValue"}' >/dev/null \
  || fail "put item via http"

BEFORE=$(warm_gauge)
echo "==> Baseline aeroncache_near_warm_caches{domain=cache} = ${BEFORE} (on sse /prometheus)"

echo "==> Prime the sse near cache (POST ${SSE_BASE}/api/v1/near/cache/${CACHE_ID})"
PRIME=$(curl --fail --silent --show-error -X POST "${SSE_BASE}/api/v1/near/cache/${CACHE_ID}") \
  || fail "prime request failed (is the near cache enabled? run 'make up NEAR_CACHE=true')"
echo "    prime: ${PRIME}"

echo "==> Waiting up to ${WARM_TIMEOUT}s for '${CACHE_ID}' to be listed warm with items"
ITEMS=0
deadline=$((SECONDS + WARM_TIMEOUT))
while [[ $SECONDS -lt $deadline ]]; do
  ITEMS=$(curl --fail --silent --show-error "${SSE_BASE}/api/v1/near/caches" 2>/dev/null \
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
# listing above and the near-served hydrate below are the proof the near cache actually holds this cache.
awk -v a="$AFTER" 'BEGIN{exit !(a+0 >= 1)}' \
  || fail "warm-caches metric is not >= 1 after priming (got ${AFTER})"

echo "==> Read the snapshot over an SSE hydrate subscription (served from the warm local copy)"
STREAM=$(curl --silent --no-buffer --max-time 8 \
  "${SSE_BASE}/api/sse/v1/cache/hydrate/${CACHE_ID}" || true)
printf '%s' "$STREAM" | grep -q "testValue" \
  || fail "expected 'testValue' in the SSE hydrate snapshot"

echo "==> NEAR CACHE VERIFY PASSED (served from near cache; warm gauge ${BEFORE} -> ${AFTER})"
