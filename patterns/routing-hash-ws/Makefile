# Pattern: routing-hash-ws
#
# Shard by HASH of the cache id to one of N WebSocket readers — the streaming, unidirectional variant
# of routing-hash-http. N independent (backend + ws reader + http writer) shards run behind one Ingress
# whose nginx server-snippet hashes the cache id out of the request path:
#   subscribe /api/ws/v1/cache/<id> -> aeroncache-ws-<shard>    (shard = crc32(id) % SHARDS)
#   write     /api/v1/cache/<id>    -> aeroncache-http-<shard>  (same shard — the subscribe is read-only)
# Reads and writes for a given id hash to the same shard, so they share one backend. The bidi endpoint
# carries the id in the frame (not the path), so it is not path-routed. Unlike routing-ws (a static
# alpha->0, beta->1 map), ANY cache id routes with no per-id config. The hashing runs in an
# ingress-nginx server-snippet, so the controller must allow snippet annotations (common/ingress.sh
# allow-snippets, done by `deploy` / CI prereqs.sh).
#
# CACHE_TYPE selects the backend for every shard:
#   make up                       # clustered (default)
#   make up CACHE_TYPE=ephemeral  # single-node ephemeral
# SHARDS sets the shard count (default 3). NEAR_CACHE=true composes (near cache on every interface).

PATTERN       := routing-hash-ws
NAMESPACE     ?= aeroncache-patterns
CACHE_TYPE    ?= clustered
NODES         ?= 3
SHARDS        ?= 3
WAIT_TIMEOUT  ?= 900s

INGRESS       := true

# Verify runs in command mode: smoke.sh health-gates shard 0's http writer, then verify-hash-ws.mjs
# proves deterministic sharding (and isolation) through the ingress using its own port-forwards.
SMOKE_SERVICE := svc/aeroncache-http-0
SMOKE_PORT    := 7070
SMOKE_MODE    := command
SMOKE_CMD     := node verify-hash-ws.mjs
export CACHE_TYPE NODES SHARDS

include ../../common/pattern.mk

# --- Guards -----------------------------------------------------------------
ifeq ($(filter $(CACHE_TYPE),clustered ephemeral),)
  $(error CACHE_TYPE must be 'clustered' or 'ephemeral' (got '$(CACHE_TYPE)'))
endif
ifeq ($(shell echo '$(NODES)' | grep -qE '^[1-9][0-9]*$$' && echo ok),)
  $(error NODES must be a positive integer (got '$(NODES)'))
endif
ifeq ($(shell echo '$(SHARDS)' | grep -qE '^[1-9][0-9]*$$' && echo ok),)
  $(error SHARDS must be a positive integer (got '$(SHARDS)'))
endif

SHARD_IDS := $(shell seq 0 $$(( $(SHARDS) - 1 )))

BACKEND_GHCR := $(call ghcr_image,aeroncache-cluster,image) \
                $(call ghcr_image,aeroncache-http-clustertools,clustertools.image)
HTTP_GHCR    := $(call ghcr_image,aeroncache-http,image)
WS_GHCR      := $(call ghcr_image,aeroncache-ws,image)
ROUTER_CHART := $(ROOT_DIR)/common/aeroncache-hash-router
INGRESS_SH   := $(ROOT_DIR)/common/ingress.sh

.PHONY: deploy undeploy

deploy: ## Install SHARDS (backend + ws reader + http writer) shards + the hash-router Ingress
	@echo "Deploying routing-hash-ws: CACHE_TYPE=$(CACHE_TYPE) SHARDS=$(SHARDS) NODES=$(NODES) NEAR_CACHE=$(NEAR_CACHE) into ns '$(NAMESPACE)'"
	@set -e; ns='$(NAMESPACE)'; \
	for i in $(SHARD_IDS); do \
	  echo "--- shard $$i ---"; \
	  if [ '$(CACHE_TYPE)' = 'clustered' ]; then \
	    cl="aeroncache-cluster-$$i"; \
	    $(HELM) upgrade --install -n "$$ns" --create-namespace \
	      "$$cl" ./charts/aeroncache-cluster \
	      --set replicaCount=$(NODES) \
	      $(BACKEND_GHCR) $(ghcr_secret); \
	    addrs=""; sep=""; for n in $$(seq 0 $$(( $(NODES) - 1 ))); do \
	      addrs="$${addrs}$${sep}$${cl}-$${n}.$${cl}.$${ns}.svc.cluster.local"; sep='\,'; done; \
	    ifaceflags="--set clusterAddresses=$$addrs"; \
	  else \
	    ep="aeroncache-ephemeral-$$i"; \
	    host="$$ep-0.$$ep.$$ns.svc.cluster.local"; \
	    $(HELM) upgrade --install -n "$$ns" --create-namespace \
	      "$$ep" ./charts/aeroncache-ephemeral \
	      --set cacheMode=SINGLE \
	      --set ephemeralResponseControlEndpoint="$$host:8076" \
	      $(BACKEND_GHCR) $(ghcr_secret); \
	    ifaceflags="--set cacheMode=SINGLE --set clusterAddresses=$$host --set ephemeralRequestEndpoint=$$host:8075 --set ephemeralResponseControlEndpoint=$$host:8076"; \
	  fi; \
	  $(HELM) upgrade --install -n "$$ns" --create-namespace \
	    "aeroncache-ws-$$i" ./charts/aeroncache-ws -f values/aeroncache-ws.yaml \
	    $$ifaceflags $(NEAR_FLAGS) $(AUTOSCALE_FLAGS) $(WS_GHCR) $(ghcr_secret); \
	  $(HELM) upgrade --install -n "$$ns" --create-namespace \
	    "aeroncache-http-$$i" ./charts/aeroncache-http -f values/aeroncache-http.yaml \
	    $$ifaceflags $(NEAR_FLAGS) $(HTTP_GHCR) $(ghcr_secret); \
	done
	@echo '--- enabling snippet annotations on the ingress controller ---'
	bash $(INGRESS_SH) allow-snippets
	@echo '--- hash-router (Ingress: ws subscribe + http writes, shard = crc32(cacheId) % $(SHARDS)) ---'
	@dns=$$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null); \
	dns=$${dns:-10.96.0.10}; \
	echo "using cluster DNS resolver $$dns"; \
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-hash-router $(ROUTER_CHART) \
	  --set interface=ws \
	  --set namespace=$(NAMESPACE) \
	  --set readRelease=aeroncache-ws    --set readPort=7071 \
	  --set writeRelease=aeroncache-http --set writePort=7070 \
	  --set shardCount=$(SHARDS) \
	  --set resolver="$$dns"

undeploy: ## Uninstall the hash-router + every routing-hash-ws release in the namespace
	@ns='$(NAMESPACE)'; \
	$(HELM) uninstall -n "$$ns" aeroncache-hash-router --ignore-not-found; \
	rels=$$($(HELM) ls -n "$$ns" -q 2>/dev/null | grep -E '^aeroncache-(cluster|ephemeral|http|ws)-[0-9]+$$' || true); \
	if [ -n "$$rels" ]; then \
	  echo "Uninstalling:"; echo "$$rels" | sed 's/^/  /'; \
	  for r in $$rels; do $(HELM) uninstall -n "$$ns" "$$r" --ignore-not-found; done; \
	else \
	  echo "No routing-hash-ws releases found in '$$ns'."; \
	fi
