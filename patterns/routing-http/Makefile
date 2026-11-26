# Pattern: routing-http
#
# Route by cache id to the http gateway that owns that cache. Two independent (backend + http gateway)
# pairs run side by side (as in multi-cache); a single Ingress in front of them sends every request to
# the gateway that owns the cache named in its path:
#   cache "alpha" -> aeroncache-http-0  (-> backend 0)
#   cache "beta"  -> aeroncache-http-1  (-> backend 1)
# CACHE_TYPE selects the backend for BOTH instances:
#   make up                       # clustered (default)
#   make up CACHE_TYPE=ephemeral  # single-node ephemeral
# NEAR_CACHE=true composes (a near cache on each gateway), exactly as in multi-cache.

PATTERN       := routing-http
NAMESPACE     ?= aeroncache-patterns
CACHE_TYPE    ?= clustered
NODES         ?= 3
WAIT_TIMEOUT  ?= 600s

# The front door is a real Ingress, so `make up` must install an ingress-nginx controller first.
INGRESS       := true

# Verify runs in command mode: smoke.sh health-gates instance 0's gateway, then verify-routing.sh
# proves routing by cache id (and isolation) through the ingress using its own port-forwards.
SMOKE_SERVICE := svc/aeroncache-http-0
SMOKE_PORT    := 7070
SMOKE_MODE    := command
SMOKE_CMD     := bash verify-routing.sh
export CACHE_TYPE NODES

include ../../common/pattern.mk

# --- Guards (fail fast, before any helm runs) -------------------------------
ifeq ($(filter $(CACHE_TYPE),clustered ephemeral),)
  $(error CACHE_TYPE must be 'clustered' or 'ephemeral' (got '$(CACHE_TYPE)'))
endif
ifeq ($(shell echo '$(NODES)' | grep -qE '^[1-9][0-9]*$$' && echo ok),)
  $(error NODES must be a positive integer (got '$(NODES)'))
endif

# Two caches, one instance each: alpha -> instance 0, beta -> instance 1.
INSTANCES := 0 1

BACKEND_GHCR := $(call ghcr_image,aeroncache-cluster,image) \
                $(call ghcr_image,aeroncache-http-clustertools,clustertools.image)
HTTP_GHCR    := $(call ghcr_image,aeroncache-http,image)
ROUTER_CHART := $(ROOT_DIR)/common/aeroncache-router

.PHONY: deploy undeploy

deploy: ## Install 2 backend+http-gateway pairs + the router Ingress (alpha->0, beta->1)
	@echo "Deploying routing-http: CACHE_TYPE=$(CACHE_TYPE) NODES=$(NODES) NEAR_CACHE=$(NEAR_CACHE) into ns '$(NAMESPACE)'"
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
	@echo '--- router (Ingress: alpha->instance 0, beta->instance 1) ---'
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-router $(ROUTER_CHART) \
	  --set interface=http \
	  --set namespace=$(NAMESPACE) \
	  --set readRelease=aeroncache-http --set readPort=7070 \
	  --set 'routes[0].cacheId=alpha' --set 'routes[0].instance=0' \
	  --set 'routes[1].cacheId=beta'  --set 'routes[1].instance=1'

undeploy: ## Uninstall the router + every routing-http backend/gateway release in the namespace
	@ns='$(NAMESPACE)'; \
	$(HELM) uninstall -n "$$ns" aeroncache-router --ignore-not-found; \
	rels=$$($(HELM) ls -n "$$ns" -q 2>/dev/null | grep -E '^aeroncache-(cluster|ephemeral|http)-[0-9]+$$' || true); \
	if [ -n "$$rels" ]; then \
	  echo "Uninstalling:"; echo "$$rels" | sed 's/^/  /'; \
	  for r in $$rels; do $(HELM) uninstall -n "$$ns" "$$r" --ignore-not-found; done; \
	else \
	  echo "No routing-http releases found in '$$ns'."; \
	fi
