#!/usr/bin/env bash
# Verify for the monolith-ui pattern.
#
# Runs the HTTP create/put/get round-trip against the monolith (proves the backend + its HTTP API),
# then checks the UI is serving (readiness on port 3000). common/smoke.sh has already port-forwarded
# both and run the liveness/readiness gate on the monolith; it passes the monolith base as BASE and
# the UI base as BASE2.
set -euo pipefail

MONO_BASE="${BASE:?BASE (monolith HTTP API) is required}"
UI_BASE="${BASE2:?BASE2 (UI) is required}"
CACHE_ID="${CACHE_ID:-smoke-monolith-ui}"

fail() { echo "MONOLITH-UI VERIFY FAILED: $*" >&2; exit 1; }

echo "==> HTTP round-trip against the monolith (create/put/get)"
curl --fail --silent --show-error -X PUT "${MONO_BASE}/api/v1/cache/${CACHE_ID}" >/dev/null || fail "create cache"
curl --fail --silent --show-error -X POST "${MONO_BASE}/api/v1/cache/${CACHE_ID}" \
  -H 'Content-Type: application/json' -d '{"key": "testKey", "value": "testValue"}' >/dev/null || fail "put item"
RESP=$(curl --fail --silent --show-error "${MONO_BASE}/api/v1/cache/${CACHE_ID}/testKey") || fail "get item"
echo "    response: ${RESP}"
[[ "$RESP" == *"testValue"* ]] || fail "expected 'testValue', got: ${RESP}"
echo "    monolith HTTP round-trip OK"

echo "==> UI readiness (GET / on the UI)"
CODE=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --retry 10 --retry-delay 3 --retry-connrefused "${UI_BASE}/" || true)
echo "    UI returned HTTP ${CODE}"
[[ "$CODE" == "200" ]] || fail "UI did not return 200 (got ${CODE})"
echo "    UI serving OK"

echo "==> MONOLITH-UI VERIFY PASSED"
