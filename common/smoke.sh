#!/usr/bin/env bash
# Reusable smoke test for an Aeron Cache HTTP interface.
#
# Port-forwards to the pattern's HTTP Service, then runs liveness/readiness plus a
# create/put/get round-trip and asserts the value comes back. This is the same check the
# upstream helm CI uses as its "smoke pre-gate", lifted here as the shared definition of
# "is this pattern actually serving?". Used by `make verify` locally and in CI.
#
# Config via env (exported by common/pattern.mk from the pattern's Makefile):
#   NAMESPACE      k8s namespace            (default aeroncache-patterns)
#   SMOKE_SERVICE  Service to port-forward  (required, e.g. svc/aeroncache-monolith)
#   SMOKE_PORT     the Service's HTTP port  (default 7070)
#   LOCAL_PORT     localhost port to bind   (default = SMOKE_PORT)
#   CACHE_ID       cache id to exercise     (default smoke-test-cache)
set -euo pipefail

NAMESPACE="${NAMESPACE:-aeroncache-patterns}"
SMOKE_SERVICE="${SMOKE_SERVICE:?SMOKE_SERVICE is required (e.g. svc/aeroncache-monolith)}"
SMOKE_PORT="${SMOKE_PORT:-7070}"
LOCAL_PORT="${LOCAL_PORT:-$SMOKE_PORT}"
CACHE_ID="${CACHE_ID:-smoke-test-cache}"
BASE="http://localhost:${LOCAL_PORT}"

fail() { echo "SMOKE FAILED: $*" >&2; exit 1; }

echo "==> Port-forwarding ${SMOKE_SERVICE} ${LOCAL_PORT}:${SMOKE_PORT} (ns ${NAMESPACE})"
kubectl port-forward -n "$NAMESPACE" "$SMOKE_SERVICE" "${LOCAL_PORT}:${SMOKE_PORT}" >/dev/null 2>&1 &
PF_PID=$!
cleanup() { kill "$PF_PID" >/dev/null 2>&1 || true; }
trap cleanup EXIT
sleep 3

echo "==> Liveness"
curl --fail --silent --show-error --retry 10 --retry-delay 3 --retry-connrefused \
  "${BASE}/liveness/" >/dev/null || fail "liveness endpoint did not return 2xx"

echo "==> Readiness"
curl --fail --silent --show-error --retry 10 --retry-delay 3 --retry-connrefused \
  "${BASE}/readiness/" >/dev/null || fail "readiness endpoint did not return 2xx"

echo "==> Create cache '${CACHE_ID}'"
curl --fail --silent --show-error -X POST "${BASE}/api/v1/cache" \
  -H 'Content-Type: application/json' \
  -d "{\"cacheId\": \"${CACHE_ID}\"}" >/dev/null || fail "create cache"

echo "==> Put item (testKey=testValue)"
curl --fail --silent --show-error -X POST "${BASE}/api/v1/cache/${CACHE_ID}" \
  -H 'Content-Type: application/json' \
  -d '{"key": "testKey", "value": "testValue"}' >/dev/null || fail "put item"

echo "==> Get item"
RESP=$(curl --fail --silent --show-error -X GET "${BASE}/api/v1/cache/${CACHE_ID}/testKey") \
  || fail "get item"
echo "    response: ${RESP}"
[[ "$RESP" == *"testValue"* ]] || fail "expected 'testValue' in response, got: ${RESP}"

echo "==> SMOKE PASSED"
