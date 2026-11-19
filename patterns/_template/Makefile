# Pattern: __PATTERN__
#
# Set the variables below, then define `deploy` and `undeploy`. Everything else
# (up/down/verify/wait/status/logs/cluster-up/cluster-down) comes from common/pattern.mk.

PATTERN       := __PATTERN__
NAMESPACE     ?= aeroncache

# What `make verify` port-forwards to, and the HTTP port it serves.
SMOKE_SERVICE := svc/aeroncache-REPLACE
SMOKE_PORT    := 7070

include ../../common/pattern.mk

# --- Deploy / undeploy ------------------------------------------------------
# Install the vendored chart(s) under ./charts. Point every image value at the pinned GHCR
# release with $(call ghcr_image,<image-name>,<values-key>); add $(ghcr_secret) for private pkgs.
.PHONY: deploy undeploy

deploy: ## Install this pattern's charts
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  REPLACE ./charts/REPLACE -f values/REPLACE.yaml \
	  $(call ghcr_image,REPLACE,image) $(ghcr_secret)

undeploy: ## Uninstall this pattern's charts
	$(HELM) uninstall -n $(NAMESPACE) REPLACE --ignore-not-found
