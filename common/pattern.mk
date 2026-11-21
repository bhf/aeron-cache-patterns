# Shared Make targets for a pattern.
#
# A pattern's Makefile sets a few variables, defines `deploy` and `undeploy` (the actual
# helm install/uninstall for its vendored charts), then includes this file:
#
#     PATTERN       := monolith
#     NAMESPACE     ?= aeroncache-patterns
#     SMOKE_SERVICE := svc/aeroncache-monolith   # what `make verify` port-forwards to
#     SMOKE_PORT    := 7070
#     include ../../common/pattern.mk
#     deploy:   ; $(HELM) upgrade --install ...
#     undeploy: ; $(HELM) uninstall ...
#
# This file provides: cluster-up/down, up/down, redeploy, wait, verify, status, logs, help.
# Local default cluster is minikube; set CLUSTER=kind to use kind (CI does this).

# Resolve common/ and repo root from this file's own path, so a pattern works from any dir.
COMMON_DIR := $(patsubst %/,%,$(dir $(lastword $(MAKEFILE_LIST))))
ROOT_DIR   := $(abspath $(COMMON_DIR)/..)

include $(ROOT_DIR)/versions.env
include $(COMMON_DIR)/ghcr.mk

NAMESPACE     ?= aeroncache-patterns
SMOKE_PORT    ?= 7070
WAIT_TIMEOUT  ?= 300s
CLUSTER       ?= minikube
CLUSTER_NAME  ?= aeroncache-patterns
HELM          ?= helm
KUBECTL       ?= kubectl

# Near cache (NEAR_CACHE): opt into the server-side near cache on the pattern's interface(s). When
# 'true', the interface keeps a warm local copy of a cache (subscribing to keep it warm) and serves
# reads/hydration from it instead of round-tripping to the cluster — it sets nearCacheEnabled=true on
# the interface chart(s). Near caching is a deployment OPTION, not a separate target: it is enabled with
# this variable on the normal lifecycle, which keeps one convention (`up`) for every combination. It is
# orthogonal to CACHE_TYPE, so the two compose:
#   make up                                      # clustered, no near cache (default)
#   make up CACHE_TYPE=ephemeral                 # ephemeral, no near cache
#   make up NEAR_CACHE=true                      # clustered + near cache
#   make up NEAR_CACHE=true CACHE_TYPE=ephemeral # ephemeral + near cache
# Confirm the near cache is actually being used with `make verify-near`, or via the near-cache metrics on each
# interface's /prometheus (web gateways http/ws/sse: aeroncache_near_hydrations_served_total and
# aeroncache_near_warm_caches; the Aeron gateway: aeron_gateway_near_* via the clustertools sidecar),
# and via the management endpoint GET /api/v1/near/caches.
NEAR_CACHE    ?= false
ifeq ($(filter $(NEAR_CACHE),true false),)
  $(error NEAR_CACHE must be 'true' or 'false' (got '$(NEAR_CACHE)'))
endif
NEAR_FLAGS = $(if $(filter true,$(NEAR_CACHE)),--set nearCacheEnabled=true)

# Exported so common/smoke.sh picks them up without per-pattern wiring.
export NAMESPACE SMOKE_SERVICE SMOKE_PORT LOCAL_PORT CACHE_ID SMOKE_MODE SMOKE_CMD \
       SMOKE_SERVICE2 SMOKE_PORT2 LOCAL_PORT2

.DEFAULT_GOAL := help

.PHONY: help up down deploy undeploy redeploy cluster-up cluster-down wait verify status logs

help: ## Show this pattern's targets
	@echo "Pattern: $(or $(PATTERN),$(notdir $(CURDIR)))   (cluster: $(CLUSTER))"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort -u \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-13s\033[0m %s\n",$$1,$$2}'
	@$(or $(NEAR_HELP),true)

cluster-up: ## Create/start the local cluster (minikube; CLUSTER=kind for kind)
	@CLUSTER=$(CLUSTER) CLUSTER_NAME=$(CLUSTER_NAME) KIND_CONFIG=$(KIND_CONFIG) \
	  bash $(COMMON_DIR)/cluster.sh cluster_up

cluster-down: ## Delete the local cluster
	@CLUSTER=$(CLUSTER) CLUSTER_NAME=$(CLUSTER_NAME) \
	  bash $(COMMON_DIR)/cluster.sh cluster_down

up: cluster-up deploy wait ## Create the cluster, deploy the pattern, wait for Ready
	@echo "✔ '$(or $(PATTERN),pattern)' is up in namespace '$(NAMESPACE)'. Run: make verify"

down: undeploy ## Uninstall the pattern (use 'make cluster-down' to also delete the cluster)
	@echo "✔ '$(or $(PATTERN),pattern)' uninstalled from '$(NAMESPACE)'."

redeploy: undeploy deploy wait ## Reinstall the pattern without recreating the cluster

# Near-cache targets, defined only for patterns that support near caching — i.e. those that set a
# NEAR_CMD (a verify-near script that warms a cache and asserts the near-cache metrics moved) before
# including this file. Patterns without near caching (e.g. monolith) leave NEAR_CMD unset and so never
# advertise or accept these targets.
ifneq ($(strip $(NEAR_CMD)),)
.PHONY: verify-near

# There is deliberately no `deploy-near`/`up-near` target. Near caching is a deployment option, enabled
# with the NEAR_CACHE variable on the normal lifecycle (e.g. `make up NEAR_CACHE=true`), so there is one
# convention — `up` — for every clustered/ephemeral × near on/off combination.
#
# verify-near is documented via NEAR_HELP (printed by `help`) rather than a `## ` comment: the help
# target greps the raw file text, which cannot see this ifneq, so a `## ` here would list it for every
# pattern — including ones that do not define it. NEAR_HELP lists it only where defined.
NEAR_HELP = printf "  \033[36m%-13s\033[0m %s\n" "verify-near" "Near-cache smoke test: warm a cache and assert it served the read (needs NEAR_CACHE=true)"

verify-near:
	@SMOKE_MODE=command SMOKE_CMD='$(NEAR_CMD)' bash $(COMMON_DIR)/smoke.sh
endif

wait: ## Wait for all pods in the namespace to be Ready
	@echo "Waiting for pods in '$(NAMESPACE)' to be Ready (timeout $(WAIT_TIMEOUT))..."
	@sleep 5
	@$(KUBECTL) wait -n $(NAMESPACE) --for=condition=ready pod --all --timeout=$(WAIT_TIMEOUT)

verify: ## Smoke test: port-forward the HTTP interface and run a create/put/get round-trip
	@bash $(COMMON_DIR)/smoke.sh

status: ## Show pods and services in the namespace
	@$(KUBECTL) get pods,svc -n $(NAMESPACE)

logs: ## Tail recent logs from the namespace
	@$(KUBECTL) logs -n $(NAMESPACE) --all-containers --prefix --tail=100 \
	  -l app.kubernetes.io/part-of=aeroncache 2>/dev/null \
	  || $(KUBECTL) logs -n $(NAMESPACE) --all-containers --prefix --tail=100 --selector=''
