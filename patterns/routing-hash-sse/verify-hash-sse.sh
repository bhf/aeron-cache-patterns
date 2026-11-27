#!/usr/bin/env bash
# Prove HASH routing by cache id for the routing-hash-sse pattern (streaming, unidirectional).
#
# N shards sit behind one Ingress whose server-snippet computes shard = crc32(cacheId) % N. SSE is
# read-only, so writes hash to the per-shard http writer and the SSE read hashes to the per-shard sse
# gateway — the SAME shard, so a cache written on shard s is only hydratable from sse-s. Over a set of
# cache ids chosen to span several shards this asserts:
#   1. Routed round-trip — write each id via the ingress (http write route), then read it back over a
#      routed SSE hydrate; the value streams, and the ingress reports the shard in X-Aeroncache-Shard.
#   2. Deterministic sharding — a direct SSE hydrate on the N sse gateways finds the id on EXACTLY ONE,
#      and that one is the shard the header named. (A write that reached backend s can only be hydrated
#      from sse-s, so this also proves the write and the read hashed to the same shard.)
#   3. Non-degenerate — the id set lands on at least two distinct shards.
#   4. (if python3 is present) Hash match — the owning shard equals crc32(id) % N computed independently.
#
# Run by `make verify` via common/smoke.sh (SMOKE_MODE=command), which first health-gates
# svc/aeroncache-http-0. This script does its own port-forwards.
set -euo pipefail

NAMESPACE="${NAMESPACE:-aeroncache-patterns}"
SHARDS="${SHARDS:-3}"

IDS=(users pricing alpha beta orders inventory)

ING_LOCAL=18080         # ingress controller (front door): http writes + sse reads, both hashed by id
SSE_BASE=17072          # sse reader shard i is port-forwarded to SSE_BASE+i
ING="http://localhost:${ING_LOCAL}"

fail() { echo "HASH ROUTING VERIFY FAILED: $*" >&2; exit 1; }

PF_PIDS=()
cleanup() { for p in "${PF_PIDS[@]:-}"; do kill "$p" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT

pf() { kubectl port-forward -n "$1" "$2" "$3" >/dev/null 2>&1 & PF_PIDS+=($!); }
sse_url() { echo "http://localhost:$(( SSE_BASE + $1 ))"; }

echo "==> Port-forwarding the ingress controller and all ${SHARDS} sse gateways"
pf ingress-nginx svc/ingress-nginx-controller "${ING_LOCAL}:80"
for i in $(seq 0 $(( SHARDS - 1 ))); do
  pf "$NAMESPACE" "svc/aeroncache-sse-${i}" "$(( SSE_BASE + i )):7072"
done
sleep 4

expected_shard() { # expected_shard <id> -> shard, or empty if python3 is unavailable
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -c "import zlib,sys; print(zlib.crc32(sys.argv[1].encode()) % ${SHARDS})" "$1"
}

route_write() { # route_write <id> <value> (via the ingress http write route)
  # Create (idempotent): retry transport errors / 5xx while the controller settles after its restart,
  # but accept a 400/409 too — that just means the cache already exists (so a re-run is fine).
  local code
  for _ in $(seq 1 20); do
    code=$(curl --silent -o /dev/null -w '%{http_code}' -X PUT "${ING}/api/v1/cache/$1" 2>/dev/null || echo 000)
    case "$code" in 2*|400|409) break ;; *) sleep 3 ;; esac
  done
  case "$code" in 2*|400|409) ;; *) fail "create '$1' via ingress (last HTTP ${code:-none})" ;; esac
  # Put: must succeed; --retry-all-errors covers a transient empty reply.
  curl --fail --silent --show-error --retry 10 --retry-delay 2 --retry-all-errors -X POST "${ING}/api/v1/cache/$1" \
    -H 'Content-Type: application/json' -d "{\"key\":\"testKey\",\"value\":\"$2\"}" >/dev/null \
    || fail "put '$1' via ingress"
}

# Read a cache's hydrate snapshot over SSE (-N streams it, --max-time bounds it).
sse_hydrate() { # sse_hydrate <base> <id> -> echoes the stream
  curl --silent --no-buffer --max-time 8 "$1/api/sse/v1/cache/hydrate/$2" 2>/dev/null || true
}

# Routed SSE hydrate via the ingress, capturing the shard header. Echoes "<shard>|<stream>".
routed_hydrate() { # routed_hydrate <id>
  local hdrs body shard
  hdrs=$(mktemp)
  body=$(curl --silent --no-buffer --max-time 8 -D "$hdrs" "${ING}/api/sse/v1/cache/hydrate/$1" 2>/dev/null || true)
  shard=$(grep -i '^x-aeroncache-shard:' "$hdrs" | tr -d '\r' | awk '{print $2}')
  rm -f "$hdrs"
  echo "${shard}|${body}"
}

distinct_shards=()
record_shard() { case " ${distinct_shards[*]:-} " in *" $1 "*) ;; *) distinct_shards+=("$1") ;; esac; }

echo "==> Writing ${#IDS[@]} cache ids through the ingress and checking each one's shard"
for id in "${IDS[@]}"; do
  val="val-${id}"
  route_write "$id" "$val"

  # [1] routed round-trip over SSE + the shard the ingress chose
  res=$(routed_hydrate "$id")
  shard="${res%%|*}"; stream="${res#*|}"
  printf '%s' "$stream" | grep -q "$val" || fail "routed SSE hydrate of '$id' did not stream '$val'"
  [[ "$shard" =~ ^[0-9]+$ ]] || fail "ingress did not report a shard for '$id' (X-Aeroncache-Shard empty — is the server-snippet active?)"
  (( shard >= 0 && shard < SHARDS )) || fail "'$id' routed to out-of-range shard $shard (SHARDS=$SHARDS)"

  # [2] deterministic sharding: hydratable from exactly one sse gateway, and it is the named shard
  owners=()
  for s in $(seq 0 $(( SHARDS - 1 ))); do
    printf '%s' "$(sse_hydrate "$(sse_url "$s")" "$id")" | grep -q "$val" && owners+=("$s") || true
  done
  [[ "${#owners[@]}" -eq 1 ]] || fail "'$id' hydrated from ${#owners[@]} sse gateways (${owners[*]:-none}) — expected exactly one"
  [[ "${owners[0]}" == "$shard" ]] || fail "'$id' hydrates from sse-${owners[0]} but the ingress routed it to shard $shard"

  # [4] optional independent hash cross-check
  exp=$(expected_shard "$id")
  if [[ -n "$exp" ]]; then
    [[ "$shard" == "$exp" ]] || fail "'$id' routed to shard $shard but crc32('$id') % $SHARDS = $exp"
    echo "    $id -> shard $shard (crc32 % $SHARDS = $exp) ✓"
  else
    echo "    $id -> shard $shard ✓"
  fi
  record_shard "$shard"
done

# [3] non-degenerate
if [[ "$SHARDS" -gt 1 ]]; then
  [[ "${#distinct_shards[@]}" -ge 2 ]] \
    || fail "all ${#IDS[@]} ids landed on one shard (${distinct_shards[*]}) — that is not hash distribution"
fi
echo "==> ${#IDS[@]} ids spread across ${#distinct_shards[@]} distinct shard(s): ${distinct_shards[*]}"

echo "==> HASH ROUTING VERIFY PASSED (deterministic crc32 % $SHARDS sharding over SSE, one owner per id)"
