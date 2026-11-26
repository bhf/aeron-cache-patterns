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

# Ingress controller (INGRESS): the routing patterns set this to 'true' so `make cluster-up` (and so
# `make up`) installs an ingress-nginx controller via common/ingress.sh — the front door their cache-id
# Ingress needs. Other patterns leave it 'false'. In CI the kind cluster is created by helm/kind-action
# (not `make cluster-up`), so the routing patterns install the controller from their prereqs.sh instead;
# both paths call the same common/ingress.sh, so they cannot drift.
INGRESS       ?= false
ifeq ($(filter $(INGRESS),true false),)
  $(error INGRESS must be 'true' or 'false' (got '$(INGRESS)'))
endif

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

# Observability (OBSERVABILITY): opt into the shared Prometheus + Grafana stack for this pattern. Like
# NEAR_CACHE it is a deployment OPTION on the normal lifecycle, not a separate flow — `make up
# OBSERVABILITY=true` also installs common/observability (Prometheus auto-discovers the pattern's pods
# via the prometheus.io/scrape + aeroncache.io/app-metrics-scrape annotations the charts already carry)
# and provisions this pattern's Grafana dashboard. It composes with CACHE_TYPE and NEAR_CACHE:
#   make up OBSERVABILITY=true                      # pattern + Prometheus/Grafana
#   make up OBSERVABILITY=true NEAR_CACHE=true      # + near cache (its gauges show up on the dashboard)
# The stack can also be added to / removed from an already-running pattern on its own:
#   make observability-up / make observability-down
#   make observability-grafana   # port-forward Grafana to http://localhost:3000
# `make down` always removes the stack too (safe no-op if it was never installed).
OBSERVABILITY ?= false
ifeq ($(filter $(OBSERVABILITY),true false),)
  $(error OBSERVABILITY must be 'true' or 'false' (got '$(OBSERVABILITY)'))
endif
# Conditionally made a prerequisite of up/redeploy (empty, i.e. not a prereq, when disabled).
OBS_PREREQ    = $(if $(filter true,$(OBSERVABILITY)),observability-up)
OBS_CHART     := $(ROOT_DIR)/common/observability
# Pattern-owned Grafana dashboard JSON, injected into the shared chart under this pattern's name.
# Override OBS_DASHBOARD to point elsewhere; if the file is absent the stack installs with no dashboard.
OBS_DASHBOARD ?= $(CURDIR)/dashboards/$(PATTERN).json
OBS_DASHBOARD_FLAG = $(if $(wildcard $(OBS_DASHBOARD)),--set-file grafana.dashboards.$(PATTERN)=$(OBS_DASHBOARD))

# Autoscaling (AUTOSCALE): opt into a HorizontalPodAutoscaler on the pattern's stateless interface
# tier — the http/ws/sse/gateway interfaces and the Next.js UI. It is deliberately NEVER applied to the
# RAFT cluster / ephemeral backends or the monolith: their membership is fixed (consensus + stable
# response-channel addressing), so autoscaling them would break the cache. Like NEAR_CACHE and
# OBSERVABILITY it is a deployment OPTION on the normal lifecycle, not a separate flow — `make up
# AUTOSCALE=true` sets autoscaling.enabled=true on the interface chart(s) and, because CPU HPAs compute
# utilization as a fraction of the pod's CPU request, the resource requests that make that defined. It
# composes with CACHE_TYPE, NEAR_CACHE and OBSERVABILITY:
#   make up AUTOSCALE=true
#   make up AUTOSCALE=true OBSERVABILITY=true   # watch the replica count climb on the Grafana dashboard
# The bounds and target are tunable on the same command line:
#   make up AUTOSCALE=true HPA_MIN=2 HPA_MAX=8 HPA_CPU=50
# Memory is an optional second metric: HPA_MEM=<percent of the memory request> adds a memory target
# alongside CPU (the HPA scales on whichever asks for more replicas). Unset by default — a JVM's heap
# plateaus rather than tracking load, so memory is a weak signal except with the near cache:
#   make up AUTOSCALE=true HPA_MEM=70
# HPAs need metrics-server in the cluster; `make cluster-up` (and so `make up`) installs it when
# AUTOSCALE=true (minikube addon / kind manifest). Where an interface speaks HTTP, `make verify-hpa`
# drives load against it and watches the HPA scale up (see the gated target below).
AUTOSCALE ?= false
ifeq ($(filter $(AUTOSCALE),true false),)
  $(error AUTOSCALE must be 'true' or 'false' (got '$(AUTOSCALE)'))
endif
# Demo-sane defaults (the chart scaffold ships min 1 / max 100): a small, visible scale range and a
# modest request so a load generator can cross the target quickly on a laptop cluster.
HPA_MIN         ?= 2
HPA_MAX         ?= 5
HPA_CPU         ?= 60
HPA_CPU_REQUEST ?= 100m
HPA_MEM_REQUEST ?= 256Mi
# Optional memory utilization target (% of HPA_MEM_REQUEST); empty = no memory metric on the HPA.
HPA_MEM         ?=
# Applied to an interface chart's helm install (never the backend install). Empty when disabled.
AUTOSCALE_FLAGS = $(if $(filter true,$(AUTOSCALE)),\
  --set autoscaling.enabled=true \
  --set autoscaling.minReplicas=$(HPA_MIN) \
  --set autoscaling.maxReplicas=$(HPA_MAX) \
  --set autoscaling.targetCPUUtilizationPercentage=$(HPA_CPU) \
  --set resources.requests.cpu=$(HPA_CPU_REQUEST) \
  --set resources.requests.memory=$(HPA_MEM_REQUEST) \
  $(if $(strip $(HPA_MEM)),--set autoscaling.targetMemoryUtilizationPercentage=$(HPA_MEM)))

# Exported so common/smoke.sh picks them up without per-pattern wiring.
export NAMESPACE SMOKE_SERVICE SMOKE_PORT LOCAL_PORT CACHE_ID SMOKE_MODE SMOKE_CMD \
       SMOKE_SERVICE2 SMOKE_PORT2 LOCAL_PORT2

.DEFAULT_GOAL := help

.PHONY: help up down deploy undeploy redeploy cluster-up cluster-down wait verify status logs \
        observability-up observability-down observability-grafana observability-prometheus

help: ## Show this pattern's targets
	@echo "Pattern: $(or $(PATTERN),$(notdir $(CURDIR)))   (cluster: $(CLUSTER))"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort -u \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-13s\033[0m %s\n",$$1,$$2}'
	@$(or $(NEAR_HELP),true)
	@$(or $(HPA_HELP),true)

cluster-up: ## Create/start the local cluster (minikube; CLUSTER=kind for kind)
	@CLUSTER=$(CLUSTER) CLUSTER_NAME=$(CLUSTER_NAME) KIND_CONFIG=$(KIND_CONFIG) \
	  AUTOSCALE=$(AUTOSCALE) METRICS_SERVER=$(METRICS_SERVER) INGRESS=$(INGRESS) \
	  bash $(COMMON_DIR)/cluster.sh cluster_up

cluster-down: ## Delete the local cluster
	@CLUSTER=$(CLUSTER) CLUSTER_NAME=$(CLUSTER_NAME) \
	  bash $(COMMON_DIR)/cluster.sh cluster_down

up: cluster-up deploy $(OBS_PREREQ) wait ## Create the cluster, deploy the pattern, wait for Ready (OBSERVABILITY=true adds Prometheus+Grafana)
	@echo "✔ '$(or $(PATTERN),pattern)' is up in namespace '$(NAMESPACE)'. Run: make verify"
	$(if $(filter true,$(OBSERVABILITY)),@echo "  observability on — run: make observability-grafana  ->  http://localhost:3000")

down: undeploy observability-down ## Uninstall the pattern + observability stack (use 'make cluster-down' to also delete the cluster)
	@echo "✔ '$(or $(PATTERN),pattern)' uninstalled from '$(NAMESPACE)'."

redeploy: undeploy deploy $(OBS_PREREQ) wait ## Reinstall the pattern without recreating the cluster

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

# verify-hpa: an operator-only convenience that drives HTTP load against the interface and watches the
# HorizontalPodAutoscaler scale the replica count up. Defined only for patterns whose primary smoke
# Service is an HTTP cache interface the create/put/get loop can hammer (they set HPA_LOAD := true
# before including this file); it is NOT wired into CI. It needs the pattern deployed with
# AUTOSCALE=true. Like verify-near it is advertised via HPA_HELP (the help target greps raw file text
# and cannot see this ifeq, so a `## ` comment would list it for every pattern).
ifeq ($(strip $(HPA_LOAD)),true)
.PHONY: verify-hpa
HPA_HELP = printf "  \033[36m%-13s\033[0m %s\n" "verify-hpa" "Drive HTTP load and watch the interface HPA scale up (needs AUTOSCALE=true)"

verify-hpa:
	@SMOKE_MODE=command SMOKE_CMD='bash $(COMMON_DIR)/hpa-load.sh' bash $(COMMON_DIR)/smoke.sh
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

# --- Observability (Prometheus + Grafana) -----------------------------------
# The shared chart lives in common/observability and is the same for every pattern; only the Grafana
# dashboard differs (patterns/<p>/dashboards/<p>.json), injected via --set-file. See the OBSERVABILITY
# notes above. `make up OBSERVABILITY=true` runs observability-up as part of the lifecycle; these
# targets also let you add/remove or reach the stack on their own.
observability-up: ## Install the Prometheus+Grafana stack + this pattern's dashboard (or: up OBSERVABILITY=true)
	@echo "Installing observability stack (scrape ns: $(NAMESPACE), dashboard: $(if $(OBS_DASHBOARD_FLAG),$(notdir $(OBS_DASHBOARD)),<none>))"
	$(HELM) upgrade --install -n $(NAMESPACE) --create-namespace \
	  aeroncache-observability $(OBS_CHART) \
	  --set prometheus.scrapeNamespaces={$(NAMESPACE)} \
	  $(OBS_DASHBOARD_FLAG)

observability-down: ## Uninstall the Prometheus+Grafana stack (safe if it was never installed)
	@$(HELM) uninstall -n $(NAMESPACE) aeroncache-observability --ignore-not-found

observability-grafana: ## Port-forward Grafana to http://localhost:3000 (Ctrl+C to stop)
	$(KUBECTL) port-forward -n $(NAMESPACE) svc/aeroncache-grafana 3000:3000

observability-prometheus: ## Port-forward Prometheus to http://localhost:9090/targets (Ctrl+C to stop)
	$(KUBECTL) port-forward -n $(NAMESPACE) svc/aeroncache-prometheus 9090:9090
