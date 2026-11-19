# Pattern: aeron-gateway
#
# A backend (clustered or ephemeral) plus the SBE-Aeron transport gateway — the bidirectional
# "bidi-aeron" interface. Its cache API is carried over Aeron (UDP), not HTTP, so verify is a health
# check plus a clustertools media-driver counters scrape (not an HTTP data round-trip).
# CACHE_TYPE selects the backend:
#   make up                       # clustered (default)
#   make up CACHE_TYPE=ephemeral  # single-node ephemeral

PATTERN       := aeron-gateway
NAMESPACE     ?= aeroncache-patterns
CACHE_TYPE    ?= clustered

# Health gate runs against the gateway's HTTP health server (7073); the verify script then scrapes
# the clustertools counters on the gateway pod (7080, which is not exposed via the Service).
SMOKE_SERVICE := svc/aeroncache-gateway
SMOKE_PORT    := 7073
SMOKE_MODE    := command
SMOKE_CMD     := bash verify-gateway.sh

include ../../common/pattern.mk

# --- Backend selection (CACHE_TYPE) -----------------------------------------
# The gateway needs only cacheMode + clusterAddresses for the ephemeral backend (no separate
# response-channel endpoints, unlike the http/ws/sse interfaces).
ifeq ($(CACHE_TYPE),clustered)
  BACKEND_RELEASE := aeroncache-cluster
  BACKEND_CHART   := ./charts/aeroncache-cluster
  BACKEND_EXTRA   :=
  GW_FLAGS        :=
else ifeq ($(CACHE_TYPE),ephemeral)
  BACKEND_RELEASE := aeroncache-ephemeral
  BACKEND_CHART   := ./charts/aeroncache-ephemeral
  BACKEND_EXTRA   := --set cacheMode=SINGLE
  EPH_HOST        := aeroncache-ephemeral-0.aeroncache-ephemeral.$(NAMESPACE).svc.cluster.local
  GW_FLAGS        := --set cacheMode=SINGLE --set clusterAddresses=$(EPH_HOST)
else
  $(error CACHE_TYPE must be 'clustered' or 'ephemeral' (got '$(CACHE_TYPE)'))
endif

BACKEND_GHCR := $(call ghcr_image,aeroncache-cluster,image) \
                $(call ghcr_image,aeroncache-http-clustertools,clustertools.image)
GATEWAY_GHCR := $(call ghcr_image,aeroncache-gateway,image) \
                $(call ghcr_image,aeroncache-http-clustertools,clustertools.image)

.PHONY: deploy undeploy

deploy: ## Install the $(CACHE_TYPE) backend + the aeron transport gateway
	@echo "Deploying aeron-gateway pattern with CACHE_TYPE=$(CACHE_TYPE)"
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  $(BACKEND_RELEASE) $(BACKEND_CHART) \
	  $(BACKEND_EXTRA) $(BACKEND_GHCR) $(ghcr_secret)
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-gateway ./charts/aeroncache-gateway -f values/aeroncache-gateway.yaml \
	  $(GW_FLAGS) $(GATEWAY_GHCR) $(ghcr_secret)

undeploy: ## Uninstall the gateway + backend (either backend)
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-gateway --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-cluster --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-ephemeral --ignore-not-found
