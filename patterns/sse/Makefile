# Pattern: sse
#
# A backend (clustered or ephemeral) plus the SSE streaming interface. SSE is uni-directional
# (read-only), so this pattern also deploys the HTTP interface as the writer: the verify writes an
# item via http and reads it back over an SSE subscription. CACHE_TYPE selects the backend:
#   make up                       # clustered (default)
#   make up CACHE_TYPE=ephemeral  # single-node ephemeral

PATTERN       := sse
NAMESPACE     ?= aeroncache-patterns
CACHE_TYPE    ?= clustered

# Verify writes via http (7070) and reads the stream via sse (7072). The sse interface is primary
# (the liveness/readiness gate runs against it); http is the secondary writer.
SMOKE_SERVICE  := svc/aeroncache-sse
SMOKE_PORT     := 7072
SMOKE_SERVICE2 := svc/aeroncache-http
SMOKE_PORT2    := 7070
SMOKE_MODE     := command
SMOKE_CMD      := SSE_BASE="$$BASE" HTTP_BASE="$$BASE2" bash verify-sse.sh

include ../../common/pattern.mk

# --- Backend selection (CACHE_TYPE) -----------------------------------------
# IFACE_FLAGS is applied to BOTH the http and sse interfaces so they point at the same backend.
ifeq ($(CACHE_TYPE),clustered)
  BACKEND_RELEASE := aeroncache-cluster
  BACKEND_CHART   := ./charts/aeroncache-cluster
  BACKEND_EXTRA   :=
  IFACE_FLAGS     :=
else ifeq ($(CACHE_TYPE),ephemeral)
  BACKEND_RELEASE := aeroncache-ephemeral
  BACKEND_CHART   := ./charts/aeroncache-ephemeral
  BACKEND_EXTRA   := --set cacheMode=SINGLE
  EPH_HOST        := aeroncache-ephemeral-0.aeroncache-ephemeral.$(NAMESPACE).svc.cluster.local
  IFACE_FLAGS     := --set cacheMode=SINGLE \
                     --set clusterAddresses=$(EPH_HOST) \
                     --set ephemeralRequestEndpoint=$(EPH_HOST):8075 \
                     --set ephemeralResponseControlEndpoint=$(EPH_HOST):8076
else
  $(error CACHE_TYPE must be 'clustered' or 'ephemeral' (got '$(CACHE_TYPE)'))
endif

BACKEND_GHCR := $(call ghcr_image,aeroncache-cluster,image) \
                $(call ghcr_image,aeroncache-http-clustertools,clustertools.image)

.PHONY: deploy undeploy

deploy: ## Install the $(CACHE_TYPE) backend + the sse interface (+ http writer)
	@echo "Deploying sse pattern with CACHE_TYPE=$(CACHE_TYPE)"
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  $(BACKEND_RELEASE) $(BACKEND_CHART) \
	  $(BACKEND_EXTRA) $(BACKEND_GHCR) $(ghcr_secret)
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-sse ./charts/aeroncache-sse -f values/aeroncache-sse.yaml \
	  $(IFACE_FLAGS) $(call ghcr_image,aeroncache-sse,image) $(ghcr_secret)
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-http ./charts/aeroncache-http -f values/aeroncache-http.yaml \
	  $(IFACE_FLAGS) $(call ghcr_image,aeroncache-http,image) $(ghcr_secret)

undeploy: ## Uninstall the sse + http interfaces + backend
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-sse --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-http --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-cluster --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-ephemeral --ignore-not-found
