# Pattern: routing-ws-keyed
#
# Split the WebSocket subscribe endpoint across two gateways that share one backend, behind a single
# Ingress, by whether the subscription is KEYED:
#   keyed  /api/ws/v1/cache/<id>?keys=<key> -> aeroncache-ws-keyed   (filtered to specific keys)
#   stream /api/ws/v1/cache/<id>            -> aeroncache-ws-stream  (whole-cache unidirectional stream)
#
# A keyed subscription is NOT a different path — it is the same subscribe URL with a `keys` query
# parameter (comma-separated `cacheId:key` or bare `key` filters; omitted = the whole cache). So, unlike
# routing-ws-split (disjoint path prefixes routed natively), this cannot be a path rule: ingress path
# matching ignores the query string. The front-door Ingress (common/aeroncache-ws-keyed-router) decides
# the split inside an nginx server-snippet that reads $arg_keys and proxies to the chosen gateway — so
# the controller must allow snippet annotations (common/ingress.sh allow-snippets, done by `deploy` /
# CI prereqs.sh), the same requirement as the hash-routing patterns.
#
# Both gateways point at ONE shared backend, so a write (over either gateway's bidi endpoint) is visible
# to subscriptions on both. CACHE_TYPE selects the shared backend; NEAR_CACHE=true composes (near cache
# on both gateways):
#   make up                       # clustered backend + keyed + stream gateways (default)
#   make up CACHE_TYPE=ephemeral  # single-node ephemeral backend + keyed + stream gateways
#   make verify                   # prove the split: keyed sub->keyed gw, whole-cache sub->stream gw, shared backend

PATTERN       := routing-ws-keyed
NAMESPACE     ?= aeroncache-patterns
CACHE_TYPE    ?= clustered
NODES         ?= 3
WAIT_TIMEOUT  ?= 900s

# The keyed-router Ingress needs an ingress-nginx controller WITH snippet annotations enabled (the
# routing runs in a server-snippet). INGRESS=true makes `make cluster-up` install the controller
# locally; `deploy` enables allow-snippets; CI does both from prereqs.sh.
INGRESS       := true

# Verify runs in command mode: smoke.sh health-gates the stream gateway Service, then
# verify-ws-keyed.mjs proves the keyed/whole-cache split through the ingress (it owns its own
# port-forwards: the ingress controller + each gateway Service for metrics).
SMOKE_SERVICE := svc/aeroncache-ws-stream
SMOKE_PORT    := 7071
SMOKE_MODE    := command
SMOKE_CMD     := node verify-ws-keyed.mjs
CACHE_ID      := routing-ws-keyed
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
# One shared backend feeds BOTH gateways (so a write is visible to subscriptions on either).
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
ROUTER_CHART := $(ROOT_DIR)/common/aeroncache-ws-keyed-router
INGRESS_SH   := $(ROOT_DIR)/common/ingress.sh

.PHONY: deploy undeploy

deploy: ## Install the shared backend + the keyed + stream ws gateways + the keyed-router Ingress
	@echo "Deploying routing-ws-keyed: CACHE_TYPE=$(CACHE_TYPE) NODES=$(NODES) NEAR_CACHE=$(NEAR_CACHE) into ns '$(NAMESPACE)'"
	@echo '--- shared backend ($(CACHE_TYPE)) ---'
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  $(BACKEND_RELEASE) $(BACKEND_CHART) \
	  $(BACKEND_EXTRA) $(BACKEND_GHCR) $(ghcr_secret)
	@echo '--- keyed gateway (serves ?keys=... subscriptions) ---'
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-ws-keyed ./charts/aeroncache-ws -f values/aeroncache-ws-keyed.yaml \
	  $(WS_FLAGS) $(NEAR_FLAGS) $(WS_GHCR) $(ghcr_secret)
	@echo '--- stream gateway (serves whole-cache subscriptions) ---'
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-ws-stream ./charts/aeroncache-ws -f values/aeroncache-ws-stream.yaml \
	  $(WS_FLAGS) $(NEAR_FLAGS) $(WS_GHCR) $(ghcr_secret)
	@echo '--- enabling snippet annotations on the ingress controller ---'
	bash $(INGRESS_SH) allow-snippets
	@echo '--- keyed-router (Ingress: ?keys=...->keyed gw, else->stream gw) ---'
	@dns=$$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null); \
	dns=$${dns:-10.96.0.10}; \
	echo "using cluster DNS resolver $$dns"; \
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-ws-keyed-router $(ROUTER_CHART) \
	  --set namespace=$(NAMESPACE) \
	  --set keyed.service=aeroncache-ws-keyed \
	  --set stream.service=aeroncache-ws-stream \
	  --set resolver="$$dns"

undeploy: ## Uninstall the keyed-router + both gateways + backend
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-ws-keyed-router --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-ws-stream --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-ws-keyed --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-cluster --ignore-not-found
	$(HELM) uninstall -n $(NAMESPACE) aeroncache-ephemeral --ignore-not-found
