#!/usr/bin/env bash
# Verify both caches in the mixed-cache-types pattern — the clustered one and the ephemeral one.
#
# Each gateway fronts its own backend of a different type, so we exercise them independently: for each
# gateway we port-forward it to a distinct local port and run a create/put/get round-trip, asserting
# the value reads back. A green run proves the clustered (RAFT) cache and the ephemeral (SINGLE) cache
# are both serving, side by side in one namespace. Run via `make verify` (common/smoke.sh calls this
# in command mode after health-gating the clustered gateway).
#
# Env (exported by the Makefile / common/pattern.mk):
#   NAMESPACE   k8s namespace   (default aeroncache-patterns)
set -euo pipefail

NAMESPACE="${NAMESPACE:-aeroncache-patterns}"
GATEWAY_PORT=7070
# High base to avoid clashing with smoke.sh's own 7070 forward of the clustered gateway.
LOCAL_PORT_BASE="${LOCAL_PORT_BASE:-17070}"

# type-label -> gateway service name. Index aligned with the local forward ports below.
LABELS=("clustered" "ephemeral")
SERVICES=("svc/aeroncache-http-clustered" "svc/aeroncache-http-ephemeral")

fail() { echo "MIXED-CACHE VERIFY FAILED: $*" >&2; exit 1; }

PF_PIDS=()
cleanup() { for p in "${PF_PIDS[@]:-}"; do kill "$p" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT

echo "==> Verifying 2 caches (clustered + ephemeral) in ns '${NAMESPACE}'"

for i in "${!SERVICES[@]}"; do
  label="${LABELS[$i]}"
  svc="${SERVICES[$i]}"
  lport=$(( LOCAL_PORT_BASE + i ))
  base="http://localhost:${lport}"
  cache="smoke-cache-${label}"

  echo "==> [${label}] port-forward ${svc} ${lport}:${GATEWAY_PORT}"
  kubectl port-forward -n "$NAMESPACE" "$svc" "${lport}:${GATEWAY_PORT}" >/dev/null 2>&1 &
  PF_PIDS+=($!)
  sleep 3

  echo "==> [${label}] readiness"
  curl --fail --silent --show-error --retry 10 --retry-delay 3 --retry-connrefused \
    "${base}/readiness/" >/dev/null || fail "${label} readiness did not return 2xx"

  echo "==> [${label}] create cache '${cache}'"
  curl --fail --silent --show-error -X PUT "${base}/api/v1/cache/${cache}" \
    >/dev/null || fail "${label} create cache"

  echo "==> [${label}] put item (testKey=testValue-${label})"
  curl --fail --silent --show-error -X POST "${base}/api/v1/cache/${cache}" \
    -H 'Content-Type: application/json' \
    -d "{\"key\": \"testKey\", \"value\": \"testValue-${label}\"}" >/dev/null || fail "${label} put item"

  echo "==> [${label}] get item"
  resp=$(curl --fail --silent --show-error -X GET "${base}/api/v1/cache/${cache}/testKey") \
    || fail "${label} get item"
  echo "    response: ${resp}"
  [[ "$resp" == *"testValue-${label}"* ]] || fail "${label}: expected 'testValue-${label}', got: ${resp}"

  echo "==> [${label}] OK"
done

echo "==> BOTH CACHES (clustered + ephemeral) PASSED"
