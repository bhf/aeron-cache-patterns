# Pattern: mixed-cache-types
#
# Stand up BOTH backend types at once in one namespace — a clustered (3-node RAFT) cache and an
# ephemeral (single-node SINGLE) cache — each with its own http gateway in front of it, so each
# cache can be verified on its own:
#   make up                 # clustered cache + ephemeral cache, a gateway each
#   make up NODES=5         # same, but 5 RAFT nodes for the clustered backend
#   make verify             # create/put/get against each gateway in turn
#
# Unlike the multi-cache pattern (N caches of ONE chosen type), this pattern always deploys exactly
# one of EACH type — the point is to show the two coexist. There is no CACHE_TYPE here (CI may pass
# one; it is ignored). Four Helm releases, all in the same namespace:
#   aeroncache-cluster           ← clustered backend (RAFT, NODES nodes)
#   aeroncache-http-clustered    ←   its gateway, wired to the RAFT peers
#   aeroncache-ephemeral         ← ephemeral backend (SINGLE mode, one pod)
#   aeroncache-http-ephemeral    ←   its gateway, wired to the ephemeral node
# A gateway connects to exactly one backend, so each (backend, gateway) is an independent pair. The
# backends keep their natural chart names; the two gateways are given distinct release names, so
# their resources derive from those names and don't collide. See the README ("How it works").

PATTERN       := mixed-cache-types
NAMESPACE     ?= aeroncache-patterns
NODES         ?= 3
WAIT_TIMEOUT  ?= 600s

# --- verify: create/put/get against each gateway (see verify-mixed.sh). smoke.sh first health-gates
# the clustered gateway; the script then exercises both gateways and labels each by type.
SMOKE_SERVICE := svc/aeroncache-http-clustered
SMOKE_PORT    := 7070
SMOKE_MODE    := command
SMOKE_CMD     := bash verify-mixed.sh
export NODES

# Both gateways speak HTTP REST, so offer `make verify-hpa` (drives load at the clustered gateway and
# watches its HPA scale; needs AUTOSCALE=true, which scales both gateways).
HPA_LOAD      := true

include ../../common/pattern.mk

# --- Guards (fail fast, before any helm runs) -------------------------------
ifeq ($(shell echo '$(NODES)' | grep -qE '^[1-9][0-9]*$$' && echo ok),)
  $(error NODES must be a positive integer (got '$(NODES)'))
endif

# Both backends run the aeroncache-cluster image plus the clustertools sidecar image (the ephemeral
# backend is the same image family in SINGLE mode). The gateways run the aeroncache-http image.
BACKEND_GHCR := $(call ghcr_image,aeroncache-cluster,image) \
                $(call ghcr_image,aeroncache-http-clustertools,clustertools.image)
HTTP_GHCR    := $(call ghcr_image,aeroncache-http,image)

# Release names (fixed — one of each type).
CL_BACKEND    := aeroncache-cluster
CL_GATEWAY    := aeroncache-http-clustered
EP_BACKEND    := aeroncache-ephemeral
EP_GATEWAY    := aeroncache-http-ephemeral

.PHONY: deploy undeploy

deploy: ## Install a clustered cache and an ephemeral cache, each with its own http gateway
	@echo "Deploying mixed-cache-types: clustered ($(NODES)-node RAFT) + ephemeral (SINGLE), NEAR_CACHE=$(NEAR_CACHE) into ns '$(NAMESPACE)'"
	@set -e; ns='$(NAMESPACE)'; \
	echo '--- clustered cache ---'; \
	$(HELM) upgrade --install -n "$$ns" --create-namespace \
	  "$(CL_BACKEND)" ./charts/aeroncache-cluster \
	  --set replicaCount=$(NODES) \
	  $(BACKEND_GHCR) $(ghcr_secret); \
	addrs=""; sep=""; for n in $$(seq 0 $$(( $(NODES) - 1 ))); do \
	  addrs="$${addrs}$${sep}$(CL_BACKEND)-$${n}.$(CL_BACKEND).$${ns}.svc.cluster.local"; sep='\,'; done; \
	$(HELM) upgrade --install -n "$$ns" --create-namespace \
	  "$(CL_GATEWAY)" ./charts/aeroncache-http -f values/aeroncache-http.yaml \
	  --set clusterAddresses="$$addrs" \
	  $(NEAR_FLAGS) $(AUTOSCALE_FLAGS) $(HTTP_GHCR) $(ghcr_secret); \
	echo '--- ephemeral cache ---'; \
	ephost="$(EP_BACKEND)-0.$(EP_BACKEND).$${ns}.svc.cluster.local"; \
	$(HELM) upgrade --install -n "$$ns" --create-namespace \
	  "$(EP_BACKEND)" ./charts/aeroncache-ephemeral \
	  --set cacheMode=SINGLE \
	  --set ephemeralResponseControlEndpoint="$$ephost:8076" \
	  $(BACKEND_GHCR) $(ghcr_secret); \
	$(HELM) upgrade --install -n "$$ns" --create-namespace \
	  "$(EP_GATEWAY)" ./charts/aeroncache-http -f values/aeroncache-http.yaml \
	  --set cacheMode=SINGLE \
	  --set clusterAddresses="$$ephost" \
	  --set ephemeralRequestEndpoint="$$ephost:8075" \
	  --set ephemeralResponseControlEndpoint="$$ephost:8076" \
	  $(NEAR_FLAGS) $(AUTOSCALE_FLAGS) $(HTTP_GHCR) $(ghcr_secret)

undeploy: ## Uninstall both backends and both gateways from the namespace
	@ns='$(NAMESPACE)'; \
	for r in $(CL_GATEWAY) $(CL_BACKEND) $(EP_GATEWAY) $(EP_BACKEND); do \
	  $(HELM) uninstall -n "$$ns" "$$r" --ignore-not-found; \
	done
