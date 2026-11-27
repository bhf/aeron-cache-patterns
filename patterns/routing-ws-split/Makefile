# Pattern: routing-ws-split
#
# Split ONE WebSocket interface by endpoint ROLE across two gateways that share one backend, behind a
# single Ingress:
#   bidi    /api/ws/v1/bidi      -> aeroncache-ws-bidi    (read-write command channel: create/put/get)
#   stream  /api/ws/v1/cache/<id>         -> aeroncache-ws-stream  (plain subscribe, future updates)
#   stream  /api/ws/v1/cache/hydrate/<id> -> aeroncache-ws-stream  (hydrating subscribe: snapshot first)
#
# This is a DIFFERENT routing dimension from routing-ws (route by cache id to the owning gateway) and
# hydration-lb (round-robin a warm pool): here the id is irrelevant — the request's ENDPOINT selects
# the gateway. Write/command load lands on the bidi gateway; streaming + hydration load (with or without
# hydration) lands on the stream gateway, so the two scale, tune and fail independently. The stream
# gateway runs the near cache ON (hydration served warm); the bidi gateway does not need it.
#
# Both gateways point at ONE shared backend, so a write over the bidi gateway is visible to a
# subscription on the stream gateway. The split's two endpoints have disjoint static path prefixes, so
# the front-door Ingress (common/aeroncache-ws-split-router) routes them by prefix with NO server-snippet
# and NO allow-snippets (unlike the hash-routing patterns).
#
# CACHE_TYPE selects the shared backend:
#   make up                       # clustered backend + bidi + stream gateways (default)
#   make up CACHE_TYPE=ephemeral  # single-node ephemeral backend + bidi + stream gateways
#   make verify                   # prove the split: bidi->bidi gw, subscribe/hydrate->stream gw, shared backend

PATTERN       := routing-ws-split
NAMESPACE     ?= aeroncache-patterns
CACHE_TYPE    ?= clustered
NODES         ?= 3
WAIT_TIMEOUT  ?= 900s

# The split-router Ingress needs an ingress-nginx controller (but NOT snippet annotations). INGRESS=true
# makes `make cluster-up` install it locally; CI installs it from prereqs.sh.
INGRESS       := true

# Verify runs in command mode: smoke.sh health-gates the stream gateway Service, then
# verify-ws-split.mjs proves the endpoint split through the ingress (it owns its own port-forwards: the
# ingress controller + each gateway Service for priming/metrics).
SMOKE_SERVICE := svc/aeroncache-ws-stream
SMOKE_PORT    := 7071
SMOKE_MODE    := command
SMOKE_CMD     := node verify-ws-split.mjs
CACHE_ID      := routing-ws-split
export CACHE_TYPE NODES

include ../../common/pattern.mk

# --- Guards -----------------------------------------------------------------
ifeq ($(filter $(CACHE_TYPE),clustered ephemeral),)
  $(error CACHE_TYPE must be 'clustered' or 'ephemeral' (got '$(CACHE_TYPE)'))
endif
ifeq ($(shell echo '$(NODES)' | grep -qE '^[1-9][0-9]*$$' && echo ok),)
  $(error NODES must be a positive integer (got '$(NODES)'))
endif

# --- Backend selection (CACHE_TYPE) -----------------------------------------
# One shared backend feeds BOTH gateways (so a write over bidi is visible to a stream subscription).
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
ROUTER_CHART := $(ROOT_DIR)/common/aeroncache-ws-split-router

.PHONY: deploy undeploy

deploy: ## Install the shared backend + the bidi + stream ws gateways + the split-router Ingress
	@echo "Deploying routing-ws-split: CACHE_TYPE=$(CACHE_TYPE) NODES=$(NODES) into ns '$(NAMESPACE)'"
	@echo '--- shared backend ($(CACHE_TYPE)) ---'
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  $(BACKEND_RELEASE) $(BACKEND_CHART) \
	  $(BACKEND_EXTRA) $(BACKEND_GHCR) $(ghcr_secret)
	@echo '--- bidi gateway (read-write command channel, near cache OFF) ---'
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-ws-bidi ./charts/aeroncache-ws -f values/aeroncache-ws-bidi.yaml \
	  --set nearCacheEnabled=false \
	  $(WS_FLAGS) $(WS_GHCR) $(ghcr_secret)
	@echo '--- stream gateway (subscribe + hydrate, near cache ON) ---'
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-ws-stream ./charts/aeroncache-ws -f values/aeroncache-ws-stream.yaml \
	  --set nearCacheEnabled=true \
	  $(WS_FLAGS) $(WS_GHCR) $(ghcr_secret)
	@echo '--- split-router (Ingress: bidi->bidi gw, /api/ws/v1/cache->stream gw) ---'
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-ws-split-router $(ROUTER_CHART) \
	  --set namespace=$(NAMESPACE) \
	  --set bidi.service=aeroncache-ws-bidi \
	  --set stream.service=aeroncache-ws-stream

undeploy: ## Uninstall the split-router + both gateways + backend
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-ws-split-router --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-ws-stream --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-ws-bidi --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-cluster --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-ephemeral --ignore-not-found
