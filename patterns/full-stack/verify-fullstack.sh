#!/usr/bin/env bash
# Verify for the full-stack pattern.
#
# Runs the HTTP create/put/get round-trip against the http interface (proves the backend + http),
# then checks the UI is serving (readiness on port 3000). common/smoke.sh has already port-forwarded
# both and run the liveness/readiness gate on the http interface; it passes the http base as BASE and
# the UI base as BASE2.
set -euo pipefail

HTTP_BASE="${BASE:?BASE (http interface) is required}"
UI_BASE="${BASE2:?BASE2 (UI) is required}"
CACHE_ID="${CACHE_ID:-smoke-fullstack}"

fail() { echo "FULL-STACK VERIFY FAILED: $*" >&2; exit 1; }

echo "==> HTTP round-trip (create/put/get)"
curl --fail --silent --show-error -X POST "${HTTP_BASE}/api/v1/cache" \
  -H 'Content-Type: application/json' -d "{\"cacheId\": \"${CACHE_ID}\"}" >/dev/null || fail "create cache"
curl --fail --silent --show-error -X POST "${HTTP_BASE}/api/v1/cache/${CACHE_ID}" \
  -H 'Content-Type: application/json' -d '{"key": "testKey", "value": "testValue"}' >/dev/null || fail "put item"
RESP=$(curl --fail --silent --show-error "${HTTP_BASE}/api/v1/cache/${CACHE_ID}/testKey") || fail "get item"
echo "    response: ${RESP}"
[[ "$RESP" == *"testValue"* ]] || fail "expected 'testValue', got: ${RESP}"
echo "    http round-trip OK"

echo "==> UI readiness (GET / on the UI)"
CODE=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --retry 10 --retry-delay 3 --retry-connrefused "${UI_BASE}/" || true)
echo "    UI returned HTTP ${CODE}"
[[ "$CODE" == "200" ]] || fail "UI did not return 200 (got ${CODE})"
echo "    UI serving OK"

echo "==> FULL-STACK VERIFY PASSED"
