#!/usr/bin/env bash
# CI prerequisite for routing-hash-http: install the ingress-nginx controller that the front-door
# Ingress needs, then enable snippet annotations on it. The hash routing lives in an nginx
# server-snippet, which ingress-nginx ignores unless allow-snippet-annotations + annotations-risk-level
# are set (common/ingress.sh allow-snippets). In CI the kind cluster is created by helm/kind-action
# (not `make cluster-up`), so common/cluster.sh's ensure_ingress never fires — we install and
# configure the controller from this hook. Both paths call the same common/ingress.sh, so local
# (`make up`) and CI behave identically.
set -euo pipefail
sh="$(dirname "$0")/../../common/ingress.sh"
bash "$sh" install
bash "$sh" allow-snippets
