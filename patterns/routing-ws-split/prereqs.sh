#!/usr/bin/env bash
# CI prerequisite for routing-ws-split: install the ingress-nginx controller that the split-router
# front-door Ingress needs. Like the hydration-lb / lb-router pattern — and UNLIKE the hash-routing
# patterns — this one does NOT use an nginx server-snippet: the two endpoints have disjoint static path
# prefixes, so the controller routes them by prefix and upgrades WebSocket natively. There is therefore
# no `allow-snippets` step here.
#
# In CI the kind cluster is created by helm/kind-action (not `make cluster-up`), so common/cluster.sh's
# ensure_ingress never fires — we install the controller from this hook. Both paths call the same
# common/ingress.sh, so local (`make up`, INGRESS=true) and CI behave identically.
set -euo pipefail
sh="$(dirname "$0")/../../common/ingress.sh"
bash "$sh" install
