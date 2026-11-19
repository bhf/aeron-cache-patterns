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
