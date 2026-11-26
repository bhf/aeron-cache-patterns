#!/usr/bin/env bash
# CI prerequisite for the routing patterns: install the ingress-nginx controller that the front-door
# Ingress needs. In CI the kind cluster is created by helm/kind-action (the reusable _pattern-ci.yml
# runs this before `make deploy`), not by `make cluster-up`, so common/cluster.sh's ensure_ingress
# never fires here — we install the controller from this hook instead. Both paths call the same
# common/ingress.sh, so local (`make up`) and CI install the identical controller.
set -euo pipefail
exec bash "$(dirname "$0")/../../common/ingress.sh" install
