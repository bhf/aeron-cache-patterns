# Pattern: routing-ws
#
# Route by cache id to the WebSocket gateway that owns that cache — the streaming, unidirectional
# variant of routing-http. Two independent caches run behind one Ingress; the id in the subscribe path
# selects the gateway:
#   subscribe /api/ws/v1/cache/alpha -> aeroncache-ws-0 (-> backend 0)
#   subscribe /api/ws/v1/cache/beta  -> aeroncache-ws-1 (-> backend 1)
# The WS *bidi* endpoint (/api/ws/v1/bidi) carries the cache id in the JSON frame, not the URL, so it
# is not path-routable; this pattern routes the uni-directional *subscribe* route (id in the path).
# Writes go through a per-instance http writer, routed by the same cache id:
#   write /api/v1/cache/alpha -> aeroncache-http-0 ;  /api/v1/cache/beta -> aeroncache-http-1
# CACHE_TYPE selects the backend for both instances:
#   make up                       # clustered (default)
#   make up CACHE_TYPE=ephemeral  # single-node ephemeral
# NEAR_CACHE=true composes (near cache on every ws + http interface), as in multi-cache.

PATTERN       := routing-ws
NAMESPACE     ?= aeroncache-patterns
CACHE_TYPE    ?= clustered
NODES         ?= 3
WAIT_TIMEOUT  ?= 600s

INGRESS       := true

# Verify runs in command mode: smoke.sh health-gates instance 0's http writer, then
# verify-routing-ws.mjs (Node 22 WebSocket) proves routing by cache id (and isolation) through the
# ingress. It owns its own port-forwards.
SMOKE_SERVICE := svc/aeroncache-http-0
SMOKE_PORT    := 7070
SMOKE_MODE    := command
SMOKE_CMD     := node verify-routing-ws.mjs
export CACHE_TYPE NODES

include ../../common/pattern.mk

# --- Guards -----------------------------------------------------------------
ifeq ($(filter $(CACHE_TYPE),clustered ephemeral),)
  $(error CACHE_TYPE must be 'clustered' or 'ephemeral' (got '$(CACHE_TYPE)'))
endif
ifeq ($(shell echo '$(NODES)' | grep -qE '^[1-9][0-9]*$$' && echo ok),)
  $(error NODES must be a positive integer (got '$(NODES)'))
endif

# alpha -> instance 0, beta -> instance 1.
INSTANCES := 0 1

BACKEND_GHCR := $(call ghcr_image,aeroncache-cluster,image) \
                $(call ghcr_image,aeroncache-http-clustertools,clustertools.image)
HTTP_GHCR    := $(call ghcr_image,aeroncache-http,image)
WS_GHCR      := $(call ghcr_image,aeroncache-ws,image)
ROUTER_CHART := $(ROOT_DIR)/common/aeroncache-router

.PHONY: deploy undeploy

deploy: ## Install 2 (backend + ws reader + http writer) instances + the router Ingress
	@echo "Deploying routing-ws: CACHE_TYPE=$(CACHE_TYPE) NODES=$(NODES) NEAR_CACHE=$(NEAR_CACHE) into ns '$(NAMESPACE)'"
	@set -e; ns='$(NAMESPACE)'; \
	for i in $(INSTANCES); do \
	  echo "--- instance $$i ---"; \
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
	@echo '--- router (Ingress: ws subscribe + http writes, alpha->0, beta->1) ---'
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-router $(ROUTER_CHART) \
	  --set interface=ws \
	  --set namespace=$(NAMESPACE) \
	  --set readRelease=aeroncache-ws   --set readPort=7071 \
	  --set writeRelease=aeroncache-http --set writePort=7070 \
	  --set 'routes[0].cacheId=alpha' --set 'routes[0].instance=0' \
	  --set 'routes[1].cacheId=beta'  --set 'routes[1].instance=1'

undeploy: ## Uninstall the router + every routing-ws release in the namespace
	@ns='$(NAMESPACE)'; \
	$(HELM) uninstall -n "$$ns" aeroncache-router --ignore-not-found; \
	rels=$$($(HELM) ls -n "$$ns" -q 2>/dev/null | grep -E '^aeroncache-(cluster|ephemeral|http|ws)-[0-9]+$$' || true); \
	if [ -n "$$rels" ]; then \
	  echo "Uninstalling:"; echo "$$rels" | sed 's/^/  /'; \
	  for r in $$rels; do $(HELM) uninstall -n "$$ns" "$$r" --ignore-not-found; done; \
	else \
	  echo "No routing-ws releases found in '$$ns'."; \
	fi
