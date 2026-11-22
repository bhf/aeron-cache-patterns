# Pattern: multi-cache
#
# Stand up N independent cache instances side by side in one namespace, each with its own http
# gateway in front of it so you can verify every cache on its own. Pick the backend type and how
# many:
#   make up                                   # COUNT=2 clustered (default)
#   make up COUNT=4                            # 4 clustered caches, each a 3-node RAFT cluster + gateway
#   make up CACHE_TYPE=ephemeral COUNT=3      # 3 single-node ephemeral caches + gateway each
#   make up COUNT=2 NODES=5                    # clustered, 5 RAFT nodes per cache (NODES is clustered-only)
#
# Each instance i is two Helm releases wired as a pair, all in the same namespace:
#   aeroncache-cluster-i (or aeroncache-ephemeral-i)  ← the backend
#   aeroncache-http-i                                 ← its gateway, bound to that backend only
# A gateway connects to exactly one backend, so "N caches" means N backend+gateway pairs. See the
# README ("How it works") for the chart edits that let the singleton charts run N-up in one namespace.

PATTERN       := multi-cache
NAMESPACE     ?= aeroncache-patterns
CACHE_TYPE    ?= clustered
COUNT         ?= 2
NODES         ?= 3
WAIT_TIMEOUT  ?= 600s

# --- verify: loop a create/put/get round-trip over every gateway (see verify-multi.sh). smoke.sh
# first health-gates instance 0; the script then exercises all COUNT gateways. COUNT/CACHE_TYPE are
# exported so the script sees the same set this Makefile deployed.
SMOKE_SERVICE := svc/aeroncache-http-0
SMOKE_PORT    := 7070
SMOKE_MODE    := command
SMOKE_CMD     := bash verify-multi.sh
export COUNT CACHE_TYPE NODES

# The gateways speak HTTP REST, so offer `make verify-hpa` (drives load at gateway 0 and watches its
# HPA scale; needs AUTOSCALE=true, which scales every gateway).
HPA_LOAD      := true

include ../../common/pattern.mk

# --- Guards (fail fast, before any helm runs) -------------------------------
ifeq ($(filter $(CACHE_TYPE),clustered ephemeral),)
  $(error CACHE_TYPE must be 'clustered' or 'ephemeral' (got '$(CACHE_TYPE)'))
endif
ifeq ($(shell echo '$(COUNT)' | grep -qE '^[1-9][0-9]*$$' && echo ok),)
  $(error COUNT must be a positive integer (got '$(COUNT)'))
endif
ifeq ($(shell echo '$(NODES)' | grep -qE '^[1-9][0-9]*$$' && echo ok),)
  $(error NODES must be a positive integer (got '$(NODES)'))
endif

# Instance indices 0..COUNT-1.
INSTANCES := $(shell seq 0 $$(( $(COUNT) - 1 )))

# Both backends run the aeroncache-cluster image plus the clustertools sidecar image (the ephemeral
# backend is the same image family in SINGLE mode). The gateway runs the aeroncache-http image.
BACKEND_GHCR := $(call ghcr_image,aeroncache-cluster,image) \
                $(call ghcr_image,aeroncache-http-clustertools,clustertools.image)
HTTP_GHCR    := $(call ghcr_image,aeroncache-http,image)

.PHONY: deploy undeploy

deploy: ## Install COUNT backend+gateway pairs of CACHE_TYPE (clustered|ephemeral)
	@echo "Deploying multi-cache: COUNT=$(COUNT) CACHE_TYPE=$(CACHE_TYPE) NODES=$(NODES) NEAR_CACHE=$(NEAR_CACHE) into ns '$(NAMESPACE)'"
	@set -e; ns='$(NAMESPACE)'; \
	for i in $(INSTANCES); do \
	  echo "--- instance $$i ---"; \
	  if [ '$(CACHE_TYPE)' = 'clustered' ]; then \
	    cl="aeroncache-cluster-$$i"; \
	    $(HELM) upgrade --install -n "$$ns" --create-namespace \
	      "$$cl" ./charts/aeroncache-cluster \
	      --set replicaCount=$(NODES) \
	      --set aeroncacheClusterConfigmap="$$cl-config" \
	      $(BACKEND_GHCR) $(ghcr_secret); \
	    addrs=""; sep=""; for n in $$(seq 0 $$(( $(NODES) - 1 ))); do \
	      addrs="$${addrs}$${sep}$${cl}-$${n}.$${cl}.$${ns}.svc.cluster.local"; sep='\,'; done; \
	    $(HELM) upgrade --install -n "$$ns" --create-namespace \
	      "aeroncache-http-$$i" ./charts/aeroncache-http -f values/aeroncache-http.yaml \
	      --set aeroncacheHTTPConfigmap="aeroncache-http-$$i-config" \
	      --set clusterAddresses="$$addrs" \
	      $(NEAR_FLAGS) $(AUTOSCALE_FLAGS) $(HTTP_GHCR) $(ghcr_secret); \
	  else \
	    ep="aeroncache-ephemeral-$$i"; \
	    host="$$ep-0.$$ep.$$ns.svc.cluster.local"; \
	    $(HELM) upgrade --install -n "$$ns" --create-namespace \
	      "$$ep" ./charts/aeroncache-ephemeral \
	      --set cacheMode=SINGLE \
	      --set aeroncacheClusterConfigmap="$$ep-config" \
	      --set ephemeralResponseControlEndpoint="$$host:8076" \
	      $(BACKEND_GHCR) $(ghcr_secret); \
	    $(HELM) upgrade --install -n "$$ns" --create-namespace \
	      "aeroncache-http-$$i" ./charts/aeroncache-http -f values/aeroncache-http.yaml \
	      --set aeroncacheHTTPConfigmap="aeroncache-http-$$i-config" \
	      --set cacheMode=SINGLE \
	      --set clusterAddresses="$$host" \
	      --set ephemeralRequestEndpoint="$$host:8075" \
	      --set ephemeralResponseControlEndpoint="$$host:8076" \
	      $(NEAR_FLAGS) $(AUTOSCALE_FLAGS) $(HTTP_GHCR) $(ghcr_secret); \
	  fi; \
	done

undeploy: ## Uninstall every multi-cache backend+gateway release in the namespace
	@ns='$(NAMESPACE)'; \
	rels=$$($(HELM) ls -n "$$ns" -q 2>/dev/null | grep -E '^aeroncache-(cluster|ephemeral|http)-[0-9]+$$' || true); \
	if [ -n "$$rels" ]; then \
	  echo "Uninstalling:"; echo "$$rels" | sed 's/^/  /'; \
	  for r in $$rels; do $(HELM) uninstall -n "$$ns" "$$r" --ignore-not-found; done; \
	else \
	  echo "No multi-cache releases found in '$$ns'."; \
	fi
