#!/usr/bin/env bash
# Prove HASH routing by cache id for the routing-hash-http pattern.
#
# N independent caches (shards) run behind one Ingress whose nginx server-snippet computes
# shard = crc32(cacheId) % N and proxies every operation for that id to aeroncache-http-<shard>.
# This script asserts four things over a set of cache ids chosen to span several shards:
#   1. Routed round-trip — writing and reading each id THROUGH the ingress works and returns the right
#      value (so the id in the path selected a working gateway), and the ingress reports the shard it
#      chose in the X-Aeroncache-Shard response header.
#   2. Deterministic sharding — reading each id DIRECTLY from the N gateways finds it on EXACTLY ONE,
#      and that one is the shard the ingress header named. No round-robin, no spraying.
#   3. Non-degenerate — the id set lands on at least two distinct shards, so routing is really hashing
#      (not a constant). With the default ids this exercises all three shards.
#   4. (if python3 is present) Hash match — the owning shard equals crc32(id) % N computed
#      independently, proving the snippet's hash function, not just that it is consistent.
#
# Run by `make verify` via common/smoke.sh (SMOKE_MODE=command), which first health-gates
# svc/aeroncache-http-0. This script does its own port-forwards: the ingress controller (the routed
# front door) and each gateway directly (for the landing/isolation checks).
set -euo pipefail

NAMESPACE="${NAMESPACE:-aeroncache-patterns}"
SHARDS="${SHARDS:-3}"

# Cache ids chosen so crc32(id) % 3 covers shards 0, 1 and 2 (users/pricing->0, alpha/beta->1,
# orders/inventory->2). The checks below never assume these specific landings — they discover the
# owner per id — but a fixed, spread-out set keeps the run reproducible and the non-degenerate check
# meaningful.
IDS=(users pricing alpha beta orders inventory)

ING_LOCAL=18080
ING="http://localhost:${ING_LOCAL}"
GW_BASE=17070   # shard i is port-forwarded to GW_BASE+i

fail() { echo "HASH ROUTING VERIFY FAILED: $*" >&2; exit 1; }

PF_PIDS=()
cleanup() { for p in "${PF_PIDS[@]:-}"; do kill "$p" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT

pf() { # pf <ns> <svc> <local:remote>
  kubectl port-forward -n "$1" "$2" "$3" >/dev/null 2>&1 &
  PF_PIDS+=($!)
}

gw_url() { echo "http://localhost:$(( GW_BASE + $1 ))"; }

echo "==> Port-forwarding the ingress controller and all ${SHARDS} gateways"
pf ingress-nginx svc/ingress-nginx-controller "${ING_LOCAL}:80"
for i in $(seq 0 $(( SHARDS - 1 ))); do
  pf "$NAMESPACE" "svc/aeroncache-http-${i}" "$(( GW_BASE + i )):7070"
done
sleep 4

# Independent reference hash (only used to cross-check the snippet's maths).
expected_shard() { # expected_shard <id> -> shard, or empty if python3 is unavailable
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -c "import zlib,sys; print(zlib.crc32(sys.argv[1].encode()) % ${SHARDS})" "$1"
}

route_write() { # route_write <id> <value> ; retry so the ingress/backends have a moment to be reachable
  curl --fail --silent --show-error --retry 15 --retry-delay 3 --retry-connrefused \
    -X PUT "${ING}/api/v1/cache/$1" >/dev/null || fail "create '$1' via ingress"
  curl --fail --silent --show-error -X POST "${ING}/api/v1/cache/$1" \
    -H 'Content-Type: application/json' -d "{\"key\":\"testKey\",\"value\":\"$2\"}" >/dev/null \
    || fail "put '$1' via ingress"
}

# GET <id> through the ingress, echoing "<shard-header>|<body>".
routed_get() { # routed_get <id>
  local hdrs body shard
  hdrs=$(mktemp)
  body=$(curl --silent --show-error -D "$hdrs" -X GET "${ING}/api/v1/cache/$1/testKey" 2>/dev/null || true)
  shard=$(grep -i '^x-aeroncache-shard:' "$hdrs" | tr -d '\r' | awk '{print $2}')
  rm -f "$hdrs"
  echo "${shard}|${body}"
}

# GET <id> directly from one gateway, echoing the body (empty-ish on a 404).
direct_get() { # direct_get <shard> <id>
  curl --silent --show-error -X GET "$(gw_url "$1")/api/v1/cache/$2/testKey" 2>/dev/null || true
}

distinct_shards=()
record_shard() { case " ${distinct_shards[*]:-} " in *" $1 "*) ;; *) distinct_shards+=("$1") ;; esac; }

echo "==> Writing ${#IDS[@]} cache ids through the ingress and checking each one's shard"
for id in "${IDS[@]}"; do
  val="val-${id}"
  route_write "$id" "$val"

  # [1] routed round-trip + the shard the ingress chose
  res=$(routed_get "$id")
  shard="${res%%|*}"; body="${res#*|}"
  [[ "$body" == *"$val"* ]] || fail "routed read of '$id' did not return '$val' (got: $body)"
  [[ "$shard" =~ ^[0-9]+$ ]] || fail "ingress did not report a shard for '$id' (X-Aeroncache-Shard empty — is the server-snippet active?)"
  (( shard >= 0 && shard < SHARDS )) || fail "'$id' routed to out-of-range shard $shard (SHARDS=$SHARDS)"

  # [2] deterministic sharding: present on exactly one gateway, and it is the shard named above
  owners=()
  for s in $(seq 0 $(( SHARDS - 1 ))); do
    [[ "$(direct_get "$s" "$id")" == *"$val"* ]] && owners+=("$s")
  done
  [[ "${#owners[@]}" -eq 1 ]] || fail "'$id' found on ${#owners[@]} gateways (${owners[*]:-none}) — expected exactly one (not round-robin / shared)"
  [[ "${owners[0]}" == "$shard" ]] || fail "'$id' lands on shard ${owners[0]} but the ingress routed it to shard $shard — header/route mismatch"

  # [4] optional independent hash cross-check
  exp=$(expected_shard "$id")
  if [[ -n "$exp" ]]; then
    [[ "$shard" == "$exp" ]] || fail "'$id' routed to shard $shard but crc32('$id') % $SHARDS = $exp — snippet hash mismatch"
    echo "    $id -> shard $shard (crc32 % $SHARDS = $exp) ✓"
  else
    echo "    $id -> shard $shard ✓"
  fi
  record_shard "$shard"
done

# [3] non-degenerate: the id set must touch more than one shard, or we have not shown hashing at all.
if [[ "$SHARDS" -gt 1 ]]; then
  [[ "${#distinct_shards[@]}" -ge 2 ]] \
    || fail "all ${#IDS[@]} ids landed on one shard (${distinct_shards[*]}) — that is not hash distribution"
fi
echo "==> ${#IDS[@]} ids spread across ${#distinct_shards[@]} distinct shard(s): ${distinct_shards[*]}"

echo "==> HASH ROUTING VERIFY PASSED (deterministic crc32 % $SHARDS sharding, one owner per id)"
