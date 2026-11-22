#!/usr/bin/env bash
# Verify every cache instance in the multi-cache pattern.
#
# For each of the COUNT gateways (svc/aeroncache-http-<i>), port-forward it to a distinct local port
# and run an independent create/put/get round-trip against it, asserting the value reads back. Each
# gateway fronts its own backend, so a green run proves every cache instance is functioning on its
# own. Run via `make verify` (common/smoke.sh calls this in command mode after health-gating
# instance 0).
#
# Env (exported by the Makefile / common/pattern.mk):
#   NAMESPACE   k8s namespace                 (default aeroncache-patterns)
#   COUNT       number of instances to check  (default 2)
#   CACHE_TYPE  clustered | ephemeral         (informational, for the banner)
set -euo pipefail

NAMESPACE="${NAMESPACE:-aeroncache-patterns}"
COUNT="${COUNT:-2}"
CACHE_TYPE="${CACHE_TYPE:-clustered}"
GATEWAY_PORT=7070
# Base for the per-instance local forwards; chosen high to avoid clashing with smoke.sh's own 7070.
LOCAL_PORT_BASE="${LOCAL_PORT_BASE:-17070}"

fail() { echo "MULTI-CACHE VERIFY FAILED: $*" >&2; exit 1; }

PF_PIDS=()
cleanup() { for p in "${PF_PIDS[@]:-}"; do kill "$p" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT

echo "==> Verifying ${COUNT} ${CACHE_TYPE} cache instance(s) in ns '${NAMESPACE}'"

for i in $(seq 0 $(( COUNT - 1 ))); do
  svc="svc/aeroncache-http-${i}"
  lport=$(( LOCAL_PORT_BASE + i ))
  base="http://localhost:${lport}"
  cache="smoke-cache-${i}"

  echo "==> [instance ${i}] port-forward ${svc} ${lport}:${GATEWAY_PORT}"
  kubectl port-forward -n "$NAMESPACE" "$svc" "${lport}:${GATEWAY_PORT}" >/dev/null 2>&1 &
  PF_PIDS+=($!)
  sleep 3

  echo "==> [instance ${i}] readiness"
  curl --fail --silent --show-error --retry 10 --retry-delay 3 --retry-connrefused \
    "${base}/readiness/" >/dev/null || fail "instance ${i} readiness did not return 2xx"

  echo "==> [instance ${i}] create cache '${cache}'"
  curl --fail --silent --show-error -X POST "${base}/api/v1/cache" \
    -H 'Content-Type: application/json' \
    -d "{\"cacheId\": \"${cache}\"}" >/dev/null || fail "instance ${i} create cache"

  echo "==> [instance ${i}] put item (testKey=testValue-${i})"
  curl --fail --silent --show-error -X POST "${base}/api/v1/cache/${cache}" \
    -H 'Content-Type: application/json' \
    -d "{\"key\": \"testKey\", \"value\": \"testValue-${i}\"}" >/dev/null || fail "instance ${i} put item"

  echo "==> [instance ${i}] get item"
  resp=$(curl --fail --silent --show-error -X GET "${base}/api/v1/cache/${cache}/testKey") \
    || fail "instance ${i} get item"
  echo "    response: ${resp}"
  [[ "$resp" == *"testValue-${i}"* ]] || fail "instance ${i}: expected 'testValue-${i}', got: ${resp}"

  echo "==> [instance ${i}] OK"
done

echo "==> ALL ${COUNT} CACHE INSTANCES PASSED"
