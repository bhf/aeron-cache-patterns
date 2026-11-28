#!/usr/bin/env bash
# Verify for the multi-cache-ui pattern.
#
# N independent cache shards run behind one hash-router Ingress, with the aeroncache-http-fanout
# aggregator fronting them for cross-cache operations, and the Next.js UI on top. This script proves
# the three things that make the pattern work, over a set of cache ids chosen to span several shards:
#
#   1. KEYED HASH ROUTING — writing/reading each id THROUGH the Ingress routes by crc32(cacheId) % N:
#      the Ingress reports the shard in X-Aeroncache-Shard, and reading the id DIRECTLY from the N
#      gateways finds it on EXACTLY ONE — the shard the header named. No round-robin, no shared backend.
#      The ids land on >= 2 distinct shards, so routing is really hashing.
#   2. FAN-OUT AGGREGATION — GET /api/v1/caches through the Ingress hits the fan-out aggregator, whose
#      response is the UNION of every gateway's caches: it contains all the written ids even though no
#      single gateway holds them all (they are sharded). And GET /api/v1/multi/snapshot-info returns
#      one entry per backend (a list of length N) — the per-backend view the multi-cache UI renders.
#   3. UI READINESS — the UI serves (GET / -> 200).
#
# Run by `make verify` via common/smoke.sh (SMOKE_MODE=command), which first health-gates
# svc/aeroncache-http-0. This script does its own port-forwards: the Ingress (the routed front door),
# each gateway directly (landing/isolation), the fan-out aggregator, and the UI.
set -euo pipefail

NAMESPACE="${NAMESPACE:-aeroncache-patterns}"
SHARDS="${SHARDS:-3}"

# Cache ids chosen so crc32(id) % 3 covers shards 0, 1 and 2 (users/pricing->0, alpha/beta->1,
# orders/inventory->2). The checks never assume these specific landings — they discover the owner per
# id — but a fixed, spread-out set keeps the run reproducible and the distribution checks meaningful.
IDS=(users pricing alpha beta orders inventory)

ING_LOCAL=18080
ING="http://localhost:${ING_LOCAL}"
GW_BASE=17070      # shard i is port-forwarded to GW_BASE+i
FANOUT_LOCAL=19090
UI_LOCAL=13000

fail() { echo "MULTI-CACHE-UI VERIFY FAILED: $*" >&2; exit 1; }

PF_PIDS=()
cleanup() { for p in "${PF_PIDS[@]:-}"; do kill "$p" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT

pf() { # pf <ns> <svc> <local:remote>
  kubectl port-forward -n "$1" "$2" "$3" >/dev/null 2>&1 &
  PF_PIDS+=($!)
}

gw_url() { echo "http://localhost:$(( GW_BASE + $1 ))"; }

echo "==> Port-forwarding the Ingress, all ${SHARDS} gateways, the fan-out aggregator and the UI"
pf ingress-nginx svc/ingress-nginx-controller "${ING_LOCAL}:80"
for i in $(seq 0 $(( SHARDS - 1 ))); do
  pf "$NAMESPACE" "svc/aeroncache-http-${i}" "$(( GW_BASE + i )):7070"
done
pf "$NAMESPACE" svc/aeroncache-http-fanout "${FANOUT_LOCAL}:7071"
pf "$NAMESPACE" svc/aeroncache-ui-nextjs "${UI_LOCAL}:3000"
sleep 5

# Independent reference hash (only used to cross-check the snippet's maths).
expected_shard() { # expected_shard <id> -> shard, or empty if python3 is unavailable
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -c "import zlib,sys; print(zlib.crc32(sys.argv[1].encode()) % ${SHARDS})" "$1"
}

route_write() { # route_write <id> <value> ; retry so the Ingress/backends have a moment to be reachable
  curl --fail --silent --show-error --retry 15 --retry-delay 3 --retry-connrefused \
    -X PUT "${ING}/api/v1/cache/$1" >/dev/null || fail "create '$1' via Ingress"
  curl --fail --silent --show-error -X POST "${ING}/api/v1/cache/$1" \
    -H 'Content-Type: application/json' -d "{\"key\":\"testKey\",\"value\":\"$2\"}" >/dev/null \
    || fail "put '$1' via Ingress"
}

# GET <id> through the Ingress, echoing "<shard-header>|<body>".
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

echo "==> [1] Writing ${#IDS[@]} cache ids through the Ingress and checking each one's shard"
for id in "${IDS[@]}"; do
  val="val-${id}"
  route_write "$id" "$val"

  # routed round-trip + the shard the Ingress chose
  res=$(routed_get "$id")
  shard="${res%%|*}"; body="${res#*|}"
  [[ "$body" == *"$val"* ]] || fail "routed read of '$id' did not return '$val' (got: $body)"
  [[ "$shard" =~ ^[0-9]+$ ]] || fail "Ingress did not report a numeric shard for '$id' (X-Aeroncache-Shard empty — is the server-snippet active?)"
  (( shard >= 0 && shard < SHARDS )) || fail "'$id' routed to out-of-range shard $shard (SHARDS=$SHARDS)"

  # deterministic sharding: present on exactly one gateway, and it is the shard named above
  owners=()
  for s in $(seq 0 $(( SHARDS - 1 ))); do
    [[ "$(direct_get "$s" "$id")" == *"$val"* ]] && owners+=("$s")
  done
  [[ "${#owners[@]}" -eq 1 ]] || fail "'$id' found on ${#owners[@]} gateways (${owners[*]:-none}) — expected exactly one (not round-robin / shared)"
  [[ "${owners[0]}" == "$shard" ]] || fail "'$id' lands on shard ${owners[0]} but the Ingress routed it to shard $shard — header/route mismatch"

  # optional independent hash cross-check
  exp=$(expected_shard "$id")
  if [[ -n "$exp" ]]; then
    [[ "$shard" == "$exp" ]] || fail "'$id' routed to shard $shard but crc32('$id') % $SHARDS = $exp — snippet hash mismatch"
    echo "    $id -> shard $shard (crc32 % $SHARDS = $exp) ✓"
  else
    echo "    $id -> shard $shard ✓"
  fi
  record_shard "$shard"
done

if [[ "$SHARDS" -gt 1 ]]; then
  [[ "${#distinct_shards[@]}" -ge 2 ]] \
    || fail "all ${#IDS[@]} ids landed on one shard (${distinct_shards[*]}) — that is not hash distribution"
fi
echo "    ${#IDS[@]} ids spread across ${#distinct_shards[@]} distinct shard(s): ${distinct_shards[*]}"

echo "==> [2] Fan-out aggregation: GET /api/v1/caches through the Ingress (-> fan-out) must union all shards"
UNION=$(curl --fail --silent --show-error --retry 10 --retry-delay 3 --retry-connrefused \
  "${ING}/api/v1/caches" 2>/dev/null) || fail "GET /api/v1/caches via Ingress (fan-out)"
for id in "${IDS[@]}"; do
  [[ "$UNION" == *"$id"* ]] \
    || fail "fan-out /api/v1/caches union is missing '$id' — it did not gather from the shard that owns it"
done
# No single gateway holds them all (the ids are sharded), so a union containing every id can only have
# come from aggregating >= 2 backends. Confirm directly: each gateway is missing at least one id.
for s in $(seq 0 $(( SHARDS - 1 ))); do
  gw_caches=$(curl --silent --show-error "$(gw_url "$s")/api/v1/caches" 2>/dev/null || true)
  missing=0
  for id in "${IDS[@]}"; do [[ "$gw_caches" == *"$id"* ]] || missing=1; done
  [[ "$missing" -eq 1 ]] \
    || fail "gateway $s alone already holds every id — the ids are not actually sharded, so the union proves nothing"
done
echo "    /api/v1/caches union contains all ${#IDS[@]} ids, none of which any single gateway holds alone ✓"

echo "==> [2b] GET /api/v1/multi/snapshot-info must return one entry per backend (${SHARDS})"
MULTI=$(curl --fail --silent --show-error "${ING}/api/v1/multi/snapshot-info" 2>/dev/null) \
  || fail "GET /api/v1/multi/snapshot-info via Ingress (fan-out)"
if command -v jq >/dev/null 2>&1; then
  n=$(printf '%s' "$MULTI" | jq 'if type=="array" then length else -1 end' 2>/dev/null || echo -1)
  [[ "$n" == "$SHARDS" ]] \
    || fail "/api/v1/multi/snapshot-info returned $n entries, expected one per backend ($SHARDS). Body: $MULTI"
  echo "    /api/v1/multi/snapshot-info returned $n per-backend entries ✓"
else
  echo "    (jq not present — skipping per-backend count; body: $MULTI)"
fi

echo "==> [3] UI readiness (GET / on the UI)"
CODE=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --retry 10 --retry-delay 3 --retry-connrefused "http://localhost:${UI_LOCAL}/" || true)
echo "    UI returned HTTP ${CODE}"
[[ "$CODE" == "200" ]] || fail "UI did not return 200 (got ${CODE})"

echo "==> MULTI-CACHE-UI VERIFY PASSED (hash-sharded keyed ops + fan-out aggregation + UI serving)"
