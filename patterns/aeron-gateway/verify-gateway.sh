#!/usr/bin/env bash
# Verify for the aeron transport gateway.
#
# The gateway's cache API is carried over Aeron (SBE, UDP) rather than HTTP, so there is no HTTP
# create/put/get to assert. common/smoke.sh has already checked the gateway's liveness/readiness
# (HTTP health server on 7073); this script then scrapes the co-located clustertools sidecar's
# media-driver counters and asserts a populated set — a running driver always publishes system
# counters, so this confirms the gateway's Aeron stack is actually up (as the upstream helm CI does).
#
# The clustertools endpoint (7080) is not exposed via the Service, so we port-forward straight to the
# gateway pod. NAMESPACE is exported by common/pattern.mk.
set -euo pipefail

NAMESPACE="${NAMESPACE:-aeroncache-patterns}"
CT_PORT="${CT_PORT:-7080}"
LOCAL_CT="${LOCAL_CT:-17080}"

fail() { echo "GATEWAY VERIFY FAILED: $*" >&2; exit 1; }

POD=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/name=aeroncache-gateway \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -n "$POD" ]] || fail "no gateway pod found (label app.kubernetes.io/name=aeroncache-gateway)"

echo "==> Scraping clustertools counters on ${POD}:${CT_PORT}"
kubectl port-forward -n "$NAMESPACE" "pod/${POD}" "${LOCAL_CT}:${CT_PORT}" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" >/dev/null 2>&1 || true' EXIT
sleep 3

OUT=$(curl --fail --silent --show-error \
  --retry 10 --retry-delay 3 --retry-connrefused --retry-all-errors \
  "http://localhost:${LOCAL_CT}/api/v1/clustertools/counters" || true)
COUNT=$(printf '%s' "$OUT" | jq -r '.count' 2>/dev/null || echo "")
DIR=$(printf '%s' "$OUT" | jq -r '.aeronDirectoryName' 2>/dev/null || echo "")
echo "    counters: count=${COUNT} dir=${DIR}"

[[ "$COUNT" =~ ^[0-9]+$ && "$COUNT" -gt 0 ]] \
  || fail "expected a populated counter set, got: ${OUT:-<empty>}"

echo "==> GATEWAY COUNTERS OK (${COUNT} counters)"
