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
#
# Finally it runs a one-shot exerciser Job (the published aeron-sample, an actual AeronGatewayClient)
# that connects over UDP and drives a real cache round-trip, and asserts the result from the Job's
# logs — proving the gateway's data path works, not just that its Aeron stack is up.
set -euo pipefail

NAMESPACE="${NAMESPACE:-aeroncache-patterns}"
CT_PORT="${CT_PORT:-7080}"
LOCAL_CT="${LOCAL_CT:-17080}"

# Exerciser Job config (defaults mirror versions.env; the Makefile passes these through).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOB_MANIFEST="${JOB_MANIFEST:-$SCRIPT_DIR/exerciser-job.yaml}"
JOB_NAME="${JOB_NAME:-aeron-sample-exerciser}"
AERON_SAMPLE_IMAGE="${AERON_SAMPLE_IMAGE:-ghcr.io/bhf/aeroncache-embedded-aeron-sample}"
AERON_SAMPLE_TAG="${AERON_SAMPLE_TAG:-latest}"
GHCR_PULL_POLICY="${GHCR_PULL_POLICY:-IfNotPresent}"
GATEWAY_HOST="${GATEWAY_HOST:-aeroncache-gateway}"
JOB_TIMEOUT="${JOB_TIMEOUT:-180}"

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

# --- Data-path round-trip via the aeron-sample exerciser Job ------------------
# Run an actual AeronGatewayClient (the published aeron-sample) against the gateway over UDP and assert
# the round-trip from its logs. NOTE: the sample exits 0 even if it can't reach the gateway (it logs an
# error and returns), so "Job completed" is NOT a success signal — we assert on log content.
echo "==> Running aeron-sample exerciser Job (${AERON_SAMPLE_IMAGE}:${AERON_SAMPLE_TAG} -> ${GATEWAY_HOST})"

[[ -f "$JOB_MANIFEST" ]] || fail "exerciser manifest not found: $JOB_MANIFEST"

cleanup_job() { kubectl delete job -n "$NAMESPACE" "$JOB_NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
# Remove any Job left from a previous run, then ensure we clean up on exit (so `make wait` after a
# verify never trips over a Completed Job pod).
cleanup_job
trap 'cleanup_job' EXIT

export AERON_SAMPLE_IMAGE AERON_SAMPLE_TAG GHCR_PULL_POLICY GATEWAY_HOST
envsubst '$AERON_SAMPLE_IMAGE $AERON_SAMPLE_TAG $GHCR_PULL_POLICY $GATEWAY_HOST' \
  < "$JOB_MANIFEST" | kubectl apply -n "$NAMESPACE" -f - >/dev/null \
  || fail "could not apply exerciser Job"

echo "    waiting up to ${JOB_TIMEOUT}s for the Job to finish"
JOB_STATE=""
deadline=$((SECONDS + JOB_TIMEOUT))
while [[ $SECONDS -lt $deadline ]]; do
  if [[ "$(kubectl get job -n "$NAMESPACE" "$JOB_NAME" -o jsonpath='{.status.succeeded}' 2>/dev/null)" == "1" ]]; then
    JOB_STATE="complete"; break
  fi
  if [[ "$(kubectl get job -n "$NAMESPACE" "$JOB_NAME" -o jsonpath='{.status.failed}' 2>/dev/null)" == "1" ]]; then
    JOB_STATE="failed"; break
  fi
  sleep 3
done

LOGS=$(kubectl logs -n "$NAMESPACE" "job/${JOB_NAME}" --tail=-1 2>/dev/null || true)
echo "----- exerciser log -----"
printf '%s\n' "$LOGS"
echo "-------------------------"

if [[ -z "$JOB_STATE" ]]; then
  echo "    Job did not finish within ${JOB_TIMEOUT}s — pod status:" >&2
  kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name="$JOB_NAME" >&2 || true
  kubectl describe pods -n "$NAMESPACE" -l app.kubernetes.io/name="$JOB_NAME" 2>/dev/null | tail -20 >&2 || true
  fail "exerciser Job timed out (image pull or scheduling problem?)"
fi

# Log-based assertions: connectivity, a real put/get round-trip over Aeron, and full completion.
printf '%s' "$LOGS" | grep -q "Connected to gateway." \
  || fail "exerciser did not connect to the gateway (no 'Connected to gateway.' in log)"
printf '%s' "$LOGS" | grep -q "Get aeron-key -> aeron-value" \
  || fail "exerciser did not read back its own write (no 'Get aeron-key -> aeron-value' in log)"
printf '%s' "$LOGS" | grep -q "^Done\.$" \
  || fail "exerciser did not complete its scenario (no 'Done.' in log)"

echo "==> GATEWAY DATA-PATH OK (aeron-sample round-trip)"
