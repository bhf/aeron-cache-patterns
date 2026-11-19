# Pattern: monolith
#
# The monolith runs a single-node Aeron Cache cluster together with the HTTP/WS/SSE interfaces
# inside one self-contained pod. One vendored chart, one image, one Service.

PATTERN       := monolith
NAMESPACE     ?= aeroncache-patterns

# What `make verify` port-forwards to: the monolith's HTTP interface.
SMOKE_SERVICE := svc/aeroncache-monolith
SMOKE_PORT    := 7070

include ../../common/pattern.mk

RELEASE := aeroncache-monolith
CHART   := ./charts/aeroncache-monolith
VALUES  := values/aeroncache-monolith.yaml

.PHONY: deploy undeploy

deploy: ## Install the monolith chart
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  $(RELEASE) $(CHART) -f $(VALUES) \
	  $(call ghcr_image,aeroncache-monolith,image) $(ghcr_secret)

undeploy: ## Uninstall the monolith chart
	$(HELM) uninstall -n $(NAMESPACE) $(RELEASE) --ignore-not-found
