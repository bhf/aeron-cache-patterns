# Pattern: aeron-gateway
#
# A clustered backend plus the SBE-Aeron transport gateway — the bidirectional "bidi-aeron"
# interface. Its cache API is carried over Aeron (UDP), not HTTP, so verify is a health check plus a
# clustertools media-driver counters scrape (not an HTTP data round-trip).
#
# Clustered only: the gateway is not supported against the ephemeral (SINGLE) backend. Upstream omits
# the gateway from its ephemeral deployments, and the gateway has no ephemeral response-channel
# wiring, so it never becomes ready against a single ephemeral node.

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

ifneq ($(CACHE_TYPE),clustered)
  $(error aeron-gateway only supports CACHE_TYPE=clustered — the gateway is not supported against the ephemeral backend)
endif

BACKEND_GHCR := $(call ghcr_image,aeroncache-cluster,image) \
                $(call ghcr_image,aeroncache-http-clustertools,clustertools.image)
GATEWAY_GHCR := $(call ghcr_image,aeroncache-gateway,image) \
                $(call ghcr_image,aeroncache-http-clustertools,clustertools.image)

.PHONY: deploy undeploy

deploy: ## Install the clustered backend + the aeron transport gateway
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-cluster ./charts/aeroncache-cluster \
	  $(BACKEND_GHCR) $(ghcr_secret)
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-gateway ./charts/aeroncache-gateway -f values/aeroncache-gateway.yaml \
	  $(GATEWAY_GHCR) $(ghcr_secret)

undeploy: ## Uninstall the gateway + backend
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-gateway --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-cluster --ignore-not-found
