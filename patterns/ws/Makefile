# Pattern: ws
#
# A backend (clustered or ephemeral) plus only the WebSocket interface. The same deployment serves
# both the uni-directional subscription routes and the bidirectional /api/ws/v1/bidi endpoint.
# CACHE_TYPE selects the backend:
#   make up                       # clustered (default)
#   make up CACHE_TYPE=ephemeral  # single-node ephemeral

PATTERN       := ws
NAMESPACE     ?= aeroncache-patterns
CACHE_TYPE    ?= clustered

# The ws interface has no HTTP REST data path, so verify runs a bidi WebSocket round-trip
# (create/put/get over /api/ws/v1/bidi) after the liveness/readiness gate. See verify-bidi.mjs.
SMOKE_SERVICE := svc/aeroncache-ws
SMOKE_PORT    := 7071
SMOKE_MODE    := command
SMOKE_CMD     := node verify-bidi.mjs

# Near-cache verify (make verify-near): a cold then warm hydrating bidi subscription, asserting the
# ws interface's own /prometheus near hit counter (aeroncache_near_hydrations_served_total) moved.
NEAR_CMD      := node verify-near.mjs

include ../../common/pattern.mk

# --- Backend selection (CACHE_TYPE) -----------------------------------------
ifeq ($(CACHE_TYPE),clustered)
  BACKEND_RELEASE := aeroncache-cluster
  BACKEND_CHART   := ./charts/aeroncache-cluster
  BACKEND_EXTRA   :=
  WS_FLAGS        :=
else ifeq ($(CACHE_TYPE),ephemeral)
  BACKEND_RELEASE := aeroncache-ephemeral
  BACKEND_CHART   := ./charts/aeroncache-ephemeral
  BACKEND_EXTRA   := --set cacheMode=SINGLE
  EPH_HOST        := aeroncache-ephemeral-0.aeroncache-ephemeral.$(NAMESPACE).svc.cluster.local
  WS_FLAGS        := --set cacheMode=SINGLE \
                     --set clusterAddresses=$(EPH_HOST) \
                     --set ephemeralRequestEndpoint=$(EPH_HOST):8075 \
                     --set ephemeralResponseControlEndpoint=$(EPH_HOST):8076
else
  $(error CACHE_TYPE must be 'clustered' or 'ephemeral' (got '$(CACHE_TYPE)'))
endif

BACKEND_GHCR := $(call ghcr_image,aeroncache-cluster,image) \
                $(call ghcr_image,aeroncache-http-clustertools,clustertools.image)

.PHONY: deploy undeploy

deploy: ## Install the $(CACHE_TYPE) backend + the ws interface
	@echo "Deploying ws pattern with CACHE_TYPE=$(CACHE_TYPE) NEAR_CACHE=$(NEAR_CACHE)"
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  $(BACKEND_RELEASE) $(BACKEND_CHART) \
	  $(BACKEND_EXTRA) $(BACKEND_GHCR) $(ghcr_secret)
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-ws ./charts/aeroncache-ws -f values/aeroncache-ws.yaml \
	  $(WS_FLAGS) $(NEAR_FLAGS) $(call ghcr_image,aeroncache-ws,image) $(ghcr_secret)

undeploy: ## Uninstall the ws interface + backend (either backend)
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-ws --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-cluster --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-ephemeral --ignore-not-found
