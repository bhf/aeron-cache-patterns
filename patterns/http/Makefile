# Pattern: http
#
# A backend (clustered or ephemeral) plus only the HTTP request/response interface.
# CACHE_TYPE selects the backend and wires the interface to it:
#   make up                       # clustered (default)
#   make up CACHE_TYPE=ephemeral  # single-node ephemeral

PATTERN       := http
NAMESPACE     ?= aeroncache-patterns
CACHE_TYPE    ?= clustered

# What `make verify` port-forwards to: the HTTP interface (same Service name for both backends).
SMOKE_SERVICE := svc/aeroncache-http
SMOKE_PORT    := 7070

# Near-cache verify (make verify-near): warms a cache through the http reads and asserts the near
# cache served them, by scraping the http interface's own /prometheus (Micrometer) near counters.
NEAR_CMD      := bash verify-near.sh

include ../../common/pattern.mk

# --- Backend selection (CACHE_TYPE) -----------------------------------------
# Both backends run the aeroncache-cluster image plus the clustertools sidecar image. The ephemeral
# backend is the same chart family in SINGLE mode (one node). The interface is pointed at whichever
# backend is selected via cacheMode + clusterAddresses (+ the ephemeral response-channel endpoints).
ifeq ($(CACHE_TYPE),clustered)
  BACKEND_RELEASE := aeroncache-cluster
  BACKEND_CHART   := ./charts/aeroncache-cluster
  BACKEND_EXTRA   :=
  # Clustered defaults in the chart are correct: cacheMode RAFT, clusterAddresses templated to the
  # release namespace. Nothing to override on the interface.
  HTTP_FLAGS      :=
else ifeq ($(CACHE_TYPE),ephemeral)
  BACKEND_RELEASE := aeroncache-ephemeral
  BACKEND_CHART   := ./charts/aeroncache-ephemeral
  BACKEND_EXTRA   := --set cacheMode=SINGLE
  EPH_HOST        := aeroncache-ephemeral-0.aeroncache-ephemeral.$(NAMESPACE).svc.cluster.local
  HTTP_FLAGS      := --set cacheMode=SINGLE \
                     --set clusterAddresses=$(EPH_HOST) \
                     --set ephemeralRequestEndpoint=$(EPH_HOST):8075 \
                     --set ephemeralResponseControlEndpoint=$(EPH_HOST):8076
else
  $(error CACHE_TYPE must be 'clustered' or 'ephemeral' (got '$(CACHE_TYPE)'))
endif

BACKEND_GHCR := $(call ghcr_image,aeroncache-cluster,image) \
                $(call ghcr_image,aeroncache-http-clustertools,clustertools.image)

.PHONY: deploy undeploy

deploy: ## Install the $(CACHE_TYPE) backend + the http interface
	@echo "Deploying http pattern with CACHE_TYPE=$(CACHE_TYPE) NEAR_CACHE=$(NEAR_CACHE)"
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  $(BACKEND_RELEASE) $(BACKEND_CHART) \
	  $(BACKEND_EXTRA) $(BACKEND_GHCR) $(ghcr_secret)
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-http ./charts/aeroncache-http -f values/aeroncache-http.yaml \
	  $(HTTP_FLAGS) $(NEAR_FLAGS) $(call ghcr_image,aeroncache-http,image) $(ghcr_secret)

undeploy: ## Uninstall the http interface + backend (either backend)
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-http --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-cluster --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-ephemeral --ignore-not-found
