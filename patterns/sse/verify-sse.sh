#!/usr/bin/env bash
# SSE round-trip smoke for the sse interface.
#
# SSE is read-only, so this writes an item via the HTTP interface and then reads it back over an SSE
# subscription (with hydration, i.e. snapshot-on-subscribe), asserting the value streams through.
# Run by `make verify` via common/smoke.sh (SMOKE_MODE=command), which port-forwards both the sse
# Service (SSE_BASE) and the http Service (HTTP_BASE) and passes them in the environment.
set -euo pipefail

HTTP_BASE="${HTTP_BASE:?HTTP_BASE is required (http interface, e.g. http://localhost:7070)}"
SSE_BASE="${SSE_BASE:?SSE_BASE is required (sse interface, e.g. http://localhost:7072)}"
CACHE_ID="${CACHE_ID:-smoke-sse}"

fail() { echo "SSE VERIFY FAILED: $*" >&2; exit 1; }

echo "==> Create cache '${CACHE_ID}' via http"
curl --fail --silent --show-error -X PUT "${HTTP_BASE}/api/v1/cache/${CACHE_ID}" >/dev/null \
  || fail "create cache via http"

echo "==> Put item (testKey=testValue) via http"
curl --fail --silent --show-error -X POST "${HTTP_BASE}/api/v1/cache/${CACHE_ID}" \
  -H 'Content-Type: application/json' -d '{"key": "testKey", "value": "testValue"}' >/dev/null \
  || fail "put item via http"

echo "==> Subscribe via SSE (hydrate) and read the snapshot"
# -N disables buffering so events arrive as they stream; --max-time bounds the read. The hydrate
# endpoint sends a snapshot of existing entries on subscribe, so the item we just wrote should appear.
STREAM=$(curl --silent --no-buffer --max-time 8 \
  "${SSE_BASE}/api/sse/v1/cache/hydrate/${CACHE_ID}" || true)
echo "----- sse stream (first lines) -----"
printf '%s\n' "$STREAM" | head -20
echo "------------------------------------"
printf '%s' "$STREAM" | grep -q "testValue" \
  || fail "expected 'testValue' in the SSE snapshot stream"

echo "==> SSE ROUND-TRIP PASSED"
