# Pattern: multi-cache-ui
#
# The multi-cache UI: N independent cache shards behind one Ingress that HASH-shards keyed operations
# on the cache id, PLUS the aeroncache-http-fanout aggregator that scatter-gathers the cross-cache
# operations — with the Next.js UI on top, pointing a single API base at the Ingress.
#
#   keyed  /api/v1/cache|counters/<id>  -> crc32(cacheId) % SHARDS -> aeroncache-http-<shard> -> backend
#   multi  /api/v1/caches,/stats,/snapshot[-info],/multi/* ...     -> aeroncache-http-fanout (all shards)
#
# So the UI lists caches that live across different shards (fan-out union) while any single-cache
# operation keys to its owning shard (hash). The hashing runs in an ingress-nginx server-snippet, so
# the controller must allow snippet annotations (common/ingress.sh allow-snippets, done by `deploy`
# and CI prereqs.sh).
#
# CACHE_TYPE selects the backend for every shard:
#   make up                       # single-node ephemeral (default — this stack is pod-heavy)
#   make up CACHE_TYPE=clustered  # 3-node RAFT cluster per shard
# SHARDS sets the shard count (default 3).

PATTERN       := multi-cache-ui
NAMESPACE     ?= aeroncache-patterns
CACHE_TYPE    ?= ephemeral
NODES         ?= 3
SHARDS        ?= 3
WAIT_TIMEOUT  ?= 900s

# The front door is a real Ingress, so `make up` installs an ingress-nginx controller first.
INGRESS       := true

# Verify runs in command mode: smoke.sh health-gates shard 0's gateway, then verify-multi-cache-ui.sh
# proves hash sharding (keyed), fan-out aggregation (multi) and UI readiness via its own port-forwards.
SMOKE_SERVICE := svc/aeroncache-http-0
SMOKE_PORT    := 7070
SMOKE_MODE    := command
SMOKE_CMD     := bash verify-multi-cache-ui.sh
export CACHE_TYPE NODES SHARDS

include ../../common/pattern.mk

# --- Guards (fail fast, before any helm runs) -------------------------------
ifeq ($(filter $(CACHE_TYPE),clustered ephemeral),)
  $(error CACHE_TYPE must be 'clustered' or 'ephemeral' (got '$(CACHE_TYPE)'))
endif
ifeq ($(shell echo '$(NODES)' | grep -qE '^[1-9][0-9]*$$' && echo ok),)
  $(error NODES must be a positive integer (got '$(NODES)'))
endif
ifeq ($(shell echo '$(SHARDS)' | grep -qE '^[1-9][0-9]*$$' && echo ok),)
  $(error SHARDS must be a positive integer (got '$(SHARDS)'))
endif

# Shard indices 0 .. SHARDS-1.
SHARD_IDS := $(shell seq 0 $$(( $(SHARDS) - 1 )))

BACKEND_GHCR := $(call ghcr_image,aeroncache-cluster,image) \
                $(call ghcr_image,aeroncache-http-clustertools,clustertools.image)
HTTP_GHCR    := $(call ghcr_image,aeroncache-http,image)
FANOUT_GHCR  := $(call ghcr_image,aeroncache-http-fanout,image)
UI_GHCR      := $(call ghcr_image,aeroncache-ui,image)
ROUTER_CHART := $(ROOT_DIR)/common/aeroncache-hash-router
INGRESS_SH   := $(ROOT_DIR)/common/ingress.sh

# The UI fetches its API base server-side from the UI pod, so it points at the in-cluster ingress-nginx
# controller Service (the hash-router front door). Keyed ops hash to a shard; aggregate/multi ops are
# proxied to the fan-out aggregator.
UI_API_BASE  := http://ingress-nginx-controller.ingress-nginx.svc.cluster.local/api/v1

.PHONY: deploy undeploy

deploy: ## Install SHARDS backend+http-gateway pairs + the fan-out aggregator + the hash-router Ingress + the UI
	@echo "Deploying multi-cache-ui: CACHE_TYPE=$(CACHE_TYPE) SHARDS=$(SHARDS) NODES=$(NODES) into ns '$(NAMESPACE)'"
	@set -e; ns='$(NAMESPACE)'; \
	for i in $(SHARD_IDS); do \
	  echo "--- shard $$i ---"; \
	  if [ '$(CACHE_TYPE)' = 'clustered' ]; then \
	    cl="aeroncache-cluster-$$i"; \
	    $(HELM) upgrade --install -n "$$ns" --create-namespace \
	      "$$cl" ./charts/aeroncache-cluster \
	      --set replicaCount=$(NODES) \
	      $(BACKEND_GHCR) $(ghcr_secret); \
	    addrs=""; sep=""; for n in $$(seq 0 $$(( $(NODES) - 1 ))); do \
	      addrs="$${addrs}$${sep}$${cl}-$${n}.$${cl}.$${ns}.svc.cluster.local"; sep='\,'; done; \
	    $(HELM) upgrade --install -n "$$ns" --create-namespace \
	      "aeroncache-http-$$i" ./charts/aeroncache-http -f values/aeroncache-http.yaml \
	      --set clusterAddresses="$$addrs" \
	      $(NEAR_FLAGS) $(AUTOSCALE_FLAGS) $(HTTP_GHCR) $(ghcr_secret); \
	  else \
	    ep="aeroncache-ephemeral-$$i"; \
	    host="$$ep-0.$$ep.$$ns.svc.cluster.local"; \
	    $(HELM) upgrade --install -n "$$ns" --create-namespace \
	      "$$ep" ./charts/aeroncache-ephemeral \
	      --set cacheMode=SINGLE \
	      --set ephemeralResponseControlEndpoint="$$host:8076" \
	      $(BACKEND_GHCR) $(ghcr_secret); \
	    $(HELM) upgrade --install -n "$$ns" --create-namespace \
	      "aeroncache-http-$$i" ./charts/aeroncache-http -f values/aeroncache-http.yaml \
	      --set cacheMode=SINGLE \
	      --set clusterAddresses="$$host" \
	      --set ephemeralRequestEndpoint="$$host:8075" \
	      --set ephemeralResponseControlEndpoint="$$host:8076" \
	      $(NEAR_FLAGS) $(AUTOSCALE_FLAGS) $(HTTP_GHCR) $(ghcr_secret); \
	  fi; \
	done
	@echo '--- fan-out aggregator (scatter-gather across all shards) ---'
	@set -e; ns='$(NAMESPACE)'; \
	gws=""; sep=""; for i in $(SHARD_IDS); do \
	  gws="$${gws}$${sep}http://aeroncache-http-$$i.$${ns}.svc.cluster.local:7070"; sep='\,'; done; \
	echo "gatewayAddresses = $$gws"; \
	$(HELM) upgrade --install -n "$$ns" --create-namespace \
	  aeroncache-http-fanout ./charts/aeroncache-http-fanout -f values/aeroncache-http-fanout.yaml \
	  --set gatewayAddresses="$$gws" \
	  $(FANOUT_GHCR) $(ghcr_secret)
	@echo '--- enabling snippet annotations on the ingress controller ---'
	bash $(INGRESS_SH) allow-snippets
	@echo '--- hash-router Ingress (keyed -> shard = crc32(cacheId) % $(SHARDS); aggregate/multi -> fan-out) ---'
	@dns=$$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null); \
	dns=$${dns:-10.96.0.10}; \
	echo "using cluster DNS resolver $$dns"; \
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-hash-router $(ROUTER_CHART) \
	  --set interface=http \
	  --set namespace=$(NAMESPACE) \
	  --set readRelease=aeroncache-http --set readPort=7070 \
	  --set writeRelease=aeroncache-http --set writePort=7070 \
	  --set shardCount=$(SHARDS) \
	  --set fanout.enabled=true \
	  --set fanout.release=aeroncache-http-fanout --set fanout.port=7071 \
	  --set resolver="$$dns"
	@echo '--- UI (AERON_CACHE_API -> hash-router Ingress, AERON_CACHE_MULTI=true) ---'
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-ui-nextjs ./charts/aeroncache-ui-nextjs -f values/aeroncache-ui-nextjs.yaml \
	  --set namespace=$(NAMESPACE) \
	  --set endpoints.api="$(UI_API_BASE)" \
	  --set endpoints.multi=true \
	  $(AUTOSCALE_FLAGS) $(UI_GHCR) $(ghcr_secret)

undeploy: ## Uninstall the UI + fan-out + hash-router + every shard backend/gateway release in the namespace
	@ns='$(NAMESPACE)'; \
	$(HELM) uninstall -n "$$ns" aeroncache-ui-nextjs --ignore-not-found; \
	$(HELM) uninstall -n "$$ns" aeroncache-hash-router --ignore-not-found; \
	$(HELM) uninstall -n "$$ns" aeroncache-http-fanout --ignore-not-found; \
	rels=$$($(HELM) ls -n "$$ns" -q 2>/dev/null | grep -E '^aeroncache-(cluster|ephemeral|http)-[0-9]+$$' || true); \
	if [ -n "$$rels" ]; then \
	  echo "Uninstalling:"; echo "$$rels" | sed 's/^/  /'; \
	  for r in $$rels; do $(HELM) uninstall -n "$$ns" "$$r" --ignore-not-found; done; \
	else \
	  echo "No multi-cache-ui shard releases found in '$$ns'."; \
	fi
