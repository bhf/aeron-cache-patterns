#!/usr/bin/env bash
# CI prerequisite for hydration-lb: install the ingress-nginx controller that the lb-router front-door
# Ingress needs. Unlike the hash-routing patterns, this one does NOT use an nginx server-snippet (the
# load balancing is ingress-nginx's own default round-robin across the pool Service's pod endpoints,
# and WebSocket is upgraded natively), so there is no `allow-snippets` step here.
#
# In CI the kind cluster is created by helm/kind-action (not `make cluster-up`), so common/cluster.sh's
# ensure_ingress never fires — we install the controller from this hook. Both paths call the same
# common/ingress.sh, so local (`make up`, INGRESS=true) and CI behave identically.
set -euo pipefail
sh="$(dirname "$0")/../../common/ingress.sh"
bash "$sh" install
