#!/usr/bin/env bash
# Operator-only HPA load generator — drives HTTP load at an Aeron Cache interface and watches the
# HorizontalPodAutoscaler scale the replica count up. Invoked by `make verify-hpa` via common/smoke.sh
# (SMOKE_MODE=command), which has already port-forwarded the interface and gated on liveness/readiness.
#
# It is a demonstration aid, not a CI check: it reports what the HPA did and always exits 0 (so a run
# that simply didn't cross the target on a slow laptop cluster is not a "failure"). Needs the pattern
# deployed with AUTOSCALE=true (otherwise there is no HPA to move).
#
# Env (BASE/CACHE_ID come from common/smoke.sh; NAMESPACE is inherited from the Makefile):
#   BASE               interface base URL, e.g. http://localhost:7070   (required)
#   NAMESPACE          namespace to watch for HPAs/pods                 (default aeroncache-patterns)
#   HPA_LOAD_DURATION  seconds to sustain load                          (default 180)
#   HPA_LOAD_WORKERS   concurrent request loops                         (default 10)
#   HPA_LOAD_VALUE_KB  approx KB per cached value (CPU per request)     (default 4)
#   HPA_LOAD_CACHE     cache id to hammer                               (default hpa-load)
set -uo pipefail

BASE="${BASE:?BASE is required (exported by common/smoke.sh)}"
NAMESPACE="${NAMESPACE:-aeroncache-patterns}"
DURATION="${HPA_LOAD_DURATION:-180}"
WORKERS="${HPA_LOAD_WORKERS:-10}"
VALUE_KB="${HPA_LOAD_VALUE_KB:-4}"
CACHE_ID="${HPA_LOAD_CACHE:-hpa-load}"

show_hpa() { kubectl get hpa -n "$NAMESPACE" 2>/dev/null || echo "  (no HPA found — deploy with AUTOSCALE=true)"; }
replica_total() {
  # Sum CURRENTREPLICAS across the namespace's HPAs (0 if none).
  kubectl get hpa -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.status.currentReplicas}{"\n"}{end}' 2>/dev/null \
    | awk '{s+=$1} END{print s+0}'
}

echo "==> HPA load: ${WORKERS} workers x ${VALUE_KB}KB values for ${DURATION}s against ${BASE} (ns ${NAMESPACE})"
if ! kubectl get hpa -n "$NAMESPACE" >/dev/null 2>&1 || [[ -z "$(kubectl get hpa -n "$NAMESPACE" -o name 2>/dev/null)" ]]; then
  echo "WARNING: no HorizontalPodAutoscaler in '${NAMESPACE}'. Deploy with AUTOSCALE=true first, e.g.:"
  echo "         make up AUTOSCALE=true"
fi

echo "==> Baseline:"; show_hpa
START_REPLICAS="$(replica_total)"

# Seed the cache the workers hammer (idempotent — a 409/4xx just means it already exists).
curl --fail --silent --show-error -X PUT "${BASE}/api/v1/cache/${CACHE_ID}" >/dev/null 2>&1 || true

# A value payload sized to make each put/get cost some server CPU (serialization + near/cluster work).
VALUE="$(head -c $((VALUE_KB * 1024)) /dev/zero | tr '\0' 'x')"

PIDS=()
STOP="$(mktemp)"; trap 'rm -f "$STOP"' EXIT
worker() {
  local i="$1" n=0
  while [[ -f "$STOP" ]]; do
    curl --silent --show-error -o /dev/null -X POST "${BASE}/api/v1/cache/${CACHE_ID}" \
      -H 'Content-Type: application/json' -d "{\"key\": \"k${i}-${n}\", \"value\": \"${VALUE}\"}" 2>/dev/null
    curl --silent -o /dev/null "${BASE}/api/v1/cache/${CACHE_ID}/k${i}-${n}" 2>/dev/null
    n=$((n + 1))
  done
}
for i in $(seq 1 "$WORKERS"); do worker "$i" & PIDS+=($!); done
echo "==> Load running (${#PIDS[@]} workers). Watching the HPA every 15s..."

# Poll the HPA for the duration, then stop the workers.
ELAPSED=0
while [[ "$ELAPSED" -lt "$DURATION" ]]; do
  sleep 15; ELAPSED=$((ELAPSED + 15))
  echo "--- t=${ELAPSED}s ---"; show_hpa
done

rm -f "$STOP"                      # signal workers to exit
for p in "${PIDS[@]}"; do wait "$p" 2>/dev/null || true; done

echo "==> Load stopped. Final state (replicas stay up until the HPA's scale-down stabilization window elapses):"
show_hpa
echo "==> Pods:"; kubectl get pods -n "$NAMESPACE" 2>/dev/null | grep -Ev 'cluster|ephemeral|monolith-[0-9]' || true

END_REPLICAS="$(replica_total)"
echo "==> Interface replicas across HPAs: ${START_REPLICAS} -> ${END_REPLICAS}"
if [[ "$END_REPLICAS" -gt "$START_REPLICAS" ]]; then
  echo "==> HPA scaled the interface up. ✔"
else
  echo "==> No scale-up observed yet. Give it longer (HPA_LOAD_DURATION=300), add workers"
  echo "    (HPA_LOAD_WORKERS=20) or lower the target (redeploy with HPA_CPU=40). Metrics also lag ~15-30s."
fi
exit 0
