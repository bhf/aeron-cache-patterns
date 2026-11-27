# Pattern: hydration-lb
#
# Load-balanced hydration: prime a POOL of near-cache WebSocket gateways and spread hydrating
# subscriptions across them. One backend feeds N identical ws gateways (one aeroncache-ws
# StatefulSet at replicaCount=GATEWAYS), each with the server-side near cache ON and primed for the
# same caches. A single Ingress (common/aeroncache-lb-router) round-robins new subscriptions across
# the pool, so the per-subscriber snapshot hydration is served warm and spread N ways instead of all
# landing on one gateway (or cold-hydrating from the cluster).
#
# This is the REPLICATION dual of routing-hash-ws's SHARDING: there each cache id has one owning
# gateway (partition caches); here every gateway holds the same caches warm (replicate caches, spread
# subscribers). The near cache is intrinsic to the pattern, so it is always on — there is no
# NEAR_CACHE=false form.
#
# CACHE_TYPE selects the shared backend; GATEWAYS sets the pool size:
#   make up                       # clustered backend + 3 warm ws gateways (default)
#   make up CACHE_TYPE=ephemeral  # single-node ephemeral backend + 3 warm ws gateways
#   make up GATEWAYS=5            # five warm ws gateways
#   make verify                   # prime every gateway, then prove hydrations spread across the pool

PATTERN       := hydration-lb
NAMESPACE     ?= aeroncache-patterns
CACHE_TYPE    ?= clustered
NODES         ?= 3
GATEWAYS      ?= 3
WAIT_TIMEOUT  ?= 900s

# The lb-router Ingress needs an ingress-nginx controller (but NOT snippet annotations). INGRESS=true
# makes `make cluster-up` install it locally; CI installs it from prereqs.sh.
INGRESS       := true

# Verify runs in command mode: smoke.sh health-gates the ws pool Service, then verify-hydration-lb.mjs
# primes every pod and proves subscriptions spread across the warm pool (it owns its own
# port-forwards: the ingress controller for subscriptions + each pod for prime/metrics).
SMOKE_SERVICE := svc/aeroncache-ws
SMOKE_PORT    := 7071
SMOKE_MODE    := command
SMOKE_CMD     := node verify-hydration-lb.mjs
CACHE_ID      := hydration-lb
export CACHE_TYPE NODES GATEWAYS

include ../../common/pattern.mk

# --- Guards -----------------------------------------------------------------
ifeq ($(filter $(CACHE_TYPE),clustered ephemeral),)
  $(error CACHE_TYPE must be 'clustered' or 'ephemeral' (got '$(CACHE_TYPE)'))
endif
ifeq ($(shell echo '$(NODES)' | grep -qE '^[1-9][0-9]*$$' && echo ok),)
  $(error NODES must be a positive integer (got '$(NODES)'))
endif
ifeq ($(shell echo '$(GATEWAYS)' | grep -qE '^[1-9][0-9]*$$' && echo ok),)
  $(error GATEWAYS must be a positive integer (got '$(GATEWAYS)'))
endif

# --- Backend selection (CACHE_TYPE) -----------------------------------------
# One shared backend feeds the whole pool (unlike routing-hash-ws, where each shard has its own).
ifeq ($(CACHE_TYPE),clustered)
  BACKEND_RELEASE := aeroncache-cluster
  BACKEND_CHART   := ./charts/aeroncache-cluster
  BACKEND_EXTRA   := --set replicaCount=$(NODES)
  WS_FLAGS        :=
else
  BACKEND_RELEASE := aeroncache-ephemeral
  BACKEND_CHART   := ./charts/aeroncache-ephemeral
  BACKEND_EXTRA   := --set cacheMode=SINGLE
  EPH_HOST        := aeroncache-ephemeral-0.aeroncache-ephemeral.$(NAMESPACE).svc.cluster.local
  WS_FLAGS        := --set cacheMode=SINGLE \
                     --set clusterAddresses=$(EPH_HOST) \
                     --set ephemeralRequestEndpoint=$(EPH_HOST):8075 \
                     --set ephemeralResponseControlEndpoint=$(EPH_HOST):8076
endif

BACKEND_GHCR := $(call ghcr_image,aeroncache-cluster,image) \
                $(call ghcr_image,aeroncache-http-clustertools,clustertools.image)
WS_GHCR      := $(call ghcr_image,aeroncache-ws,image)
ROUTER_CHART := $(ROOT_DIR)/common/aeroncache-lb-router

.PHONY: deploy undeploy

deploy: ## Install the shared backend + a pool of GATEWAYS warm ws gateways + the lb-router Ingress
	@echo "Deploying hydration-lb: CACHE_TYPE=$(CACHE_TYPE) GATEWAYS=$(GATEWAYS) NODES=$(NODES) into ns '$(NAMESPACE)'"
	@echo '--- shared backend ($(CACHE_TYPE)) ---'
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  $(BACKEND_RELEASE) $(BACKEND_CHART) \
	  $(BACKEND_EXTRA) $(BACKEND_GHCR) $(ghcr_secret)
	@echo '--- ws gateway pool (replicaCount=$(GATEWAYS), near cache ON) ---'
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-ws ./charts/aeroncache-ws -f values/aeroncache-ws.yaml \
	  --set replicaCount=$(GATEWAYS) \
	  --set nearCacheEnabled=true \
	  $(WS_FLAGS) $(WS_GHCR) $(ghcr_secret)
	@echo '--- lb-router (Ingress: round-robin subscriptions across the ws pool) ---'
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-lb-router $(ROUTER_CHART) \
	  --set namespace=$(NAMESPACE) \
	  --set service=aeroncache-ws \
	  --set port=7071

undeploy: ## Uninstall the lb-router + ws pool + backend
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-lb-router --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-ws --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-cluster --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-ephemeral --ignore-not-found
