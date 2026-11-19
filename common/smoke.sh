#!/usr/bin/env bash
# Reusable smoke test for an Aeron Cache interface.
#
# Port-forwards to the pattern's Service and checks liveness/readiness, then runs a mode-specific
# check. Used by `make verify` locally and in CI, so "green" means the same in both places.
#
# Config via env (exported by common/pattern.mk from the pattern's Makefile):
#   NAMESPACE      k8s namespace            (default aeroncache-patterns)
#   SMOKE_SERVICE  Service to port-forward  (required, e.g. svc/aeroncache-monolith)
#   SMOKE_PORT     the Service's port       (default 7070)
#   LOCAL_PORT     localhost port to bind   (default = SMOKE_PORT)
#   CACHE_ID       cache id to exercise     (default smoke-test-cache)
#   SMOKE_MODE     http | health | command  (default http)
#   SMOKE_CMD      command to run in 'command' mode (sees BASE and LOCAL_PORT in its env)
#
# Modes:
#   http     liveness/readiness + an HTTP create/put/get round-trip (REST interfaces).
#   health   liveness/readiness only (interfaces whose data path is not HTTP, e.g. the aeron gateway).
#   command  liveness/readiness, then run $SMOKE_CMD against the forwarded port (e.g. a ws round-trip).
set -euo pipefail

NAMESPACE="${NAMESPACE:-aeroncache-patterns}"
SMOKE_SERVICE="${SMOKE_SERVICE:?SMOKE_SERVICE is required (e.g. svc/aeroncache-monolith)}"
SMOKE_PORT="${SMOKE_PORT:-7070}"
LOCAL_PORT="${LOCAL_PORT:-$SMOKE_PORT}"
CACHE_ID="${CACHE_ID:-smoke-test-cache}"
SMOKE_MODE="${SMOKE_MODE:-http}"
BASE="http://localhost:${LOCAL_PORT}"

fail() { echo "SMOKE FAILED: $*" >&2; exit 1; }

echo "==> Port-forwarding ${SMOKE_SERVICE} ${LOCAL_PORT}:${SMOKE_PORT} (ns ${NAMESPACE}, mode ${SMOKE_MODE})"
kubectl port-forward -n "$NAMESPACE" "$SMOKE_SERVICE" "${LOCAL_PORT}:${SMOKE_PORT}" >/dev/null 2>&1 &
PF_PID=$!
cleanup() { kill "$PF_PID" >/dev/null 2>&1 || true; }
trap cleanup EXIT
sleep 3

# Liveness/readiness gate for every mode — the HTTP health server is present on all interfaces.
echo "==> Liveness"
curl --fail --silent --show-error --retry 10 --retry-delay 3 --retry-connrefused \
  "${BASE}/liveness/" >/dev/null || fail "liveness endpoint did not return 2xx"
echo "==> Readiness"
curl --fail --silent --show-error --retry 10 --retry-delay 3 --retry-connrefused \
  "${BASE}/readiness/" >/dev/null || fail "readiness endpoint did not return 2xx"

case "$SMOKE_MODE" in
  health)
    echo "==> Health-only mode: liveness/readiness OK"
    ;;

  http)
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
    ;;

  command)
    : "${SMOKE_CMD:?SMOKE_CMD is required for SMOKE_MODE=command}"
    echo "==> Running: ${SMOKE_CMD}"
    BASE="$BASE" LOCAL_PORT="$LOCAL_PORT" CACHE_ID="$CACHE_ID" bash -c "$SMOKE_CMD" || fail "command check failed"
    ;;

  *)
    fail "unknown SMOKE_MODE '${SMOKE_MODE}' (want http|health|command)"
    ;;
esac

echo "==> SMOKE PASSED"
