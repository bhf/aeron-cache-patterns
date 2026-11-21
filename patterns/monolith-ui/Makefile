# Pattern: monolith-ui
#
# The monolith (a single-node Aeron Cache cluster plus the HTTP/WS/SSE interfaces in one
# self-contained pod) with the Next.js UI in front of it. Two charts, two pods, two Services:
# the monolith backend and the UI. The UI talks to the monolith's HTTP API server-side and opens
# ws/sse from the browser — the monolith exposes the same ports the split interfaces do, so the UI
# needs no separate http/ws/sse deployments.

PATTERN       := monolith-ui
NAMESPACE     ?= aeroncache-patterns
WAIT_TIMEOUT  ?= 300s

# Verify: HTTP create/put/get against the monolith (primary) + UI readiness (secondary). The
# monolith serves the HTTP API on 7070; the UI serves on 3000.
SMOKE_SERVICE  := svc/aeroncache-monolith
SMOKE_PORT     := 7070
SMOKE_SERVICE2 := svc/aeroncache-ui-nextjs
SMOKE_PORT2    := 3000
SMOKE_MODE     := command
SMOKE_CMD      := bash verify-monolith-ui.sh

include ../../common/pattern.mk

RELEASE_MONOLITH := aeroncache-monolith
RELEASE_UI       := aeroncache-ui-nextjs

.PHONY: deploy undeploy

deploy: ## Install the monolith backend + the Next.js UI
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  $(RELEASE_MONOLITH) ./charts/aeroncache-monolith -f values/aeroncache-monolith.yaml \
	  $(call ghcr_image,aeroncache-monolith,image) $(ghcr_secret)
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  $(RELEASE_UI) ./charts/aeroncache-ui-nextjs -f values/aeroncache-ui-nextjs.yaml \
	  --set namespace=$(NAMESPACE) \
	  $(AUTOSCALE_FLAGS) $(call ghcr_image,aeroncache-ui,image) $(ghcr_secret)

undeploy: ## Uninstall the UI + the monolith backend
	$(HELM) uninstall -n $(NAMESPACE) $(RELEASE_UI) --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) $(RELEASE_MONOLITH) --ignore-not-found
