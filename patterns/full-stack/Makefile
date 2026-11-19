# Pattern: full-stack
#
# The complete web stack: a backend (clustered or ephemeral) + the http, ws and sse interfaces + the
# Next.js UI. This is the only pattern with the UI, which consumes http + ws + sse together.
# CACHE_TYPE selects the backend:
#   make up                       # clustered (default)
#   make up CACHE_TYPE=ephemeral  # single-node ephemeral

PATTERN       := full-stack
NAMESPACE     ?= aeroncache-patterns
CACHE_TYPE    ?= clustered
WAIT_TIMEOUT  ?= 600s

# Verify: http create/put/get (primary) + UI readiness (secondary). The ws/sse interfaces are
# covered by their own patterns; here the UI check confirms the front end is serving.
SMOKE_SERVICE  := svc/aeroncache-http
SMOKE_PORT     := 7070
SMOKE_SERVICE2 := svc/aeroncache-ui-nextjs
SMOKE_PORT2    := 3000
SMOKE_MODE     := command
SMOKE_CMD      := bash verify-fullstack.sh

include ../../common/pattern.mk

# --- Backend selection (CACHE_TYPE) -----------------------------------------
# IFACE_FLAGS is applied to the http/ws/sse interfaces so they address the selected backend. The UI
# is wired by Service name (endpoints in its chart), so it is unaffected by CACHE_TYPE.
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

deploy: ## Install the $(CACHE_TYPE) backend + http/ws/sse + UI
	@echo "Deploying full-stack pattern with CACHE_TYPE=$(CACHE_TYPE)"
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  $(BACKEND_RELEASE) $(BACKEND_CHART) \
	  $(BACKEND_EXTRA) $(BACKEND_GHCR) $(ghcr_secret)
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-http ./charts/aeroncache-http -f values/aeroncache-http.yaml \
	  $(IFACE_FLAGS) $(call ghcr_image,aeroncache-http,image) $(ghcr_secret)
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-ws ./charts/aeroncache-ws -f values/aeroncache-ws.yaml \
	  $(IFACE_FLAGS) $(call ghcr_image,aeroncache-ws,image) $(ghcr_secret)
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-sse ./charts/aeroncache-sse -f values/aeroncache-sse.yaml \
	  $(IFACE_FLAGS) $(call ghcr_image,aeroncache-sse,image) $(ghcr_secret)
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-ui-nextjs ./charts/aeroncache-ui-nextjs -f values/aeroncache-ui-nextjs.yaml \
	  --set namespace=$(NAMESPACE) \
	  $(call ghcr_image,aeroncache-ui,image) $(ghcr_secret)

undeploy: ## Uninstall the UI + interfaces + backend
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-ui-nextjs --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-http --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-ws --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-sse --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-cluster --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-ephemeral --ignore-not-found
