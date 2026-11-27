# Pattern: routing-hash-http
#
# Shard by HASH of the cache id to one of N http gateways. N independent (backend + http gateway)
# pairs run side by side (as in multi-cache); a single Ingress in front of them hashes the cache id
# out of the request path and sends every operation for that id to the owning shard:
#   shard = crc32(cacheId) % SHARDS   ->   aeroncache-http-<shard>  (-> backend <shard>)
# Unlike routing-http (a static alpha->0, beta->1 map), ANY cache id routes deterministically with no
# per-id configuration. The hashing runs in an ingress-nginx server-snippet, so the controller must
# allow snippet annotations (common/ingress.sh allow-snippets, done by `deploy` / CI prereqs.sh).
#
# CACHE_TYPE selects the backend for every shard:
#   make up                       # clustered (default)
#   make up CACHE_TYPE=ephemeral  # single-node ephemeral
# SHARDS sets the shard count (default 3). NEAR_CACHE=true composes (a near cache on each gateway).

PATTERN       := routing-hash-http
NAMESPACE     ?= aeroncache-patterns
CACHE_TYPE    ?= clustered
NODES         ?= 3
SHARDS        ?= 3
WAIT_TIMEOUT  ?= 900s

# The front door is a real Ingress, so `make up` must install an ingress-nginx controller first.
INGRESS       := true

# Verify runs in command mode: smoke.sh health-gates shard 0's gateway, then verify-hash.sh proves
# deterministic sharding (and isolation) through the ingress using its own port-forwards.
SMOKE_SERVICE := svc/aeroncache-http-0
SMOKE_PORT    := 7070
SMOKE_MODE    := command
SMOKE_CMD     := bash verify-hash.sh
export CACHE_TYPE NODES SHARDS

include ../../common/pattern.mk

# --- Guards (fail fast, before any helm runs) -------------------------------
ifeq ($(filter $(CACHE_TYPE),clustered ephemeral),)
  $(error CACHE_TYPE must be 'clustered' or 'ephemeral' (got '$(CACHE_TYPE)'))
endif
ifeq ($(shell echo '$(NODES)' | grep -qE '^[1-9][0-9]*$$' && echo ok),)
  $(error NODES must be a positive integer (got '$(NODES)'))
endif
ifeq ($(shell echo '$(SHARDS)' | grep -qE '^[1-9][0-9]*$$' && echo ok),)
  $(error SHARDS must be a positive integer (got '$(SHARDS)'))
endif

# Shard indices 0 .. SHARDS-1.
SHARD_IDS := $(shell seq 0 $$(( $(SHARDS) - 1 )))

BACKEND_GHCR := $(call ghcr_image,aeroncache-cluster,image) \
                $(call ghcr_image,aeroncache-http-clustertools,clustertools.image)
HTTP_GHCR    := $(call ghcr_image,aeroncache-http,image)
ROUTER_CHART := $(ROOT_DIR)/common/aeroncache-hash-router
INGRESS_SH   := $(ROOT_DIR)/common/ingress.sh

.PHONY: deploy undeploy

deploy: ## Install SHARDS backend+http-gateway pairs + the hash-router Ingress
	@echo "Deploying routing-hash-http: CACHE_TYPE=$(CACHE_TYPE) SHARDS=$(SHARDS) NODES=$(NODES) NEAR_CACHE=$(NEAR_CACHE) into ns '$(NAMESPACE)'"
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
	    $(HELM) upgrade --install -n "$$ns" --create-namespace \
	      "aeroncache-http-$$i" ./charts/aeroncache-http -f values/aeroncache-http.yaml \
	      --set clusterAddresses="$$addrs" \
	      $(NEAR_FLAGS) $(AUTOSCALE_FLAGS) $(HTTP_GHCR) $(ghcr_secret); \
	  else \
	    ep="aeroncache-ephemeral-$$i"; \
	    host="$$ep-0.$$ep.$$ns.svc.cluster.local"; \
	    $(HELM) upgrade --install -n "$$ns" --create-namespace \
	      "$$ep" ./charts/aeroncache-ephemeral \
	      --set cacheMode=SINGLE \
	      --set ephemeralResponseControlEndpoint="$$host:8076" \
	      $(BACKEND_GHCR) $(ghcr_secret); \
	    $(HELM) upgrade --install -n "$$ns" --create-namespace \
	      "aeroncache-http-$$i" ./charts/aeroncache-http -f values/aeroncache-http.yaml \
	      --set cacheMode=SINGLE \
	      --set clusterAddresses="$$host" \
	      --set ephemeralRequestEndpoint="$$host:8075" \
	      --set ephemeralResponseControlEndpoint="$$host:8076" \
	      $(NEAR_FLAGS) $(AUTOSCALE_FLAGS) $(HTTP_GHCR) $(ghcr_secret); \
	  fi; \
	done
	@echo '--- enabling snippet annotations on the ingress controller ---'
	bash $(INGRESS_SH) allow-snippets
	@echo '--- hash-router (Ingress: shard = crc32(cacheId) % $(SHARDS)) ---'
	@dns=$$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null); \
	dns=$${dns:-10.96.0.10}; \
	echo "using cluster DNS resolver $$dns"; \
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-hash-router $(ROUTER_CHART) \
	  --set interface=http \
	  --set namespace=$(NAMESPACE) \
	  --set readRelease=aeroncache-http --set readPort=7070 \
	  --set shardCount=$(SHARDS) \
	  --set resolver="$$dns"

undeploy: ## Uninstall the hash-router + every routing-hash-http backend/gateway release in the namespace
	@ns='$(NAMESPACE)'; \
	$(HELM) uninstall -n "$$ns" aeroncache-hash-router --ignore-not-found; \
	rels=$$($(HELM) ls -n "$$ns" -q 2>/dev/null | grep -E '^aeroncache-(cluster|ephemeral|http)-[0-9]+$$' || true); \
	if [ -n "$$rels" ]; then \
	  echo "Uninstalling:"; echo "$$rels" | sed 's/^/  /'; \
	  for r in $$rels; do $(HELM) uninstall -n "$$ns" "$$r" --ignore-not-found; done; \
	else \
	  echo "No routing-hash-http releases found in '$$ns'."; \
	fi
