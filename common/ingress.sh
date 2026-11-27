#!/usr/bin/env bash
# Install an ingress-nginx controller for the routing patterns.
#
# The repo's default clusters (minikube local, kind in CI) ship no ingress controller — only an
# optional metrics-server for HPAs. The routing patterns need a controller to serve their cache-id
# Ingress, so this installs a pinned ingress-nginx from the provider-agnostic "baremetal" manifest (a
# NodePort controller with NO `ingress-ready` nodeSelector, so it schedules on a default minikube/kind
# node) and waits for it to be ready. The controller is reached by port-forwarding
# `svc/ingress-nginx-controller -n ingress-nginx`, so no NodePort/tunnel or kind extraPortMappings are
# needed and the local and CI paths look identical.
#
# One implementation, two callers, so local and CI never drift:
#   - common/cluster.sh  ensure_ingress()   — local `make up`, when INGRESS=true
#   - patterns/routing-*/prereqs.sh          — CI, where the kind cluster is created by helm/kind-action
#                                              (not `make cluster-up`, so ensure_ingress never runs)
#
# Usage: ingress.sh install
set -euo pipefail

# Pin the controller release. Override with INGRESS_NGINX_VERSION if needed.
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.11.3}"
MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/baremetal/deploy.yaml"

install() {
  if kubectl -n ingress-nginx get deploy ingress-nginx-controller >/dev/null 2>&1; then
    echo "ingress-nginx already present; ensuring it is ready."
  else
    echo "Installing ingress-nginx ${INGRESS_NGINX_VERSION} (baremetal manifest)..."
    kubectl apply -f "$MANIFEST"
  fi

  echo "Waiting for the ingress-nginx controller to roll out..."
  kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=240s

  # Drop the admission webhook. On an ephemeral cluster its cert-patch Job can still be racing when the
  # router's Ingress is applied, which makes `helm install` fail intermittently; we don't need Ingress
  # validation for a demo, so removing the webhook makes the install deterministic.
  kubectl delete validatingwebhookconfiguration ingress-nginx-admission --ignore-not-found >/dev/null 2>&1 || true

  echo "ingress-nginx is ready (reach it via: kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80)."
}

# Enable nginx snippet annotations on the controller. ingress-nginx disables snippet annotations by
# default since v1.9 (allow-snippet-annotations: false) and classifies them as "Critical" risk, so the
# server-snippet the hash-routing front door (common/aeroncache-hash-router) uses is ignored until
# both are turned on. The other routing patterns do not need this; only routing-hash-http calls it.
# Idempotent: a no-op if the ConfigMap already has these values.
allow_snippets() {
  kubectl -n ingress-nginx get deploy ingress-nginx-controller >/dev/null 2>&1 || {
    echo "ingress-nginx is not installed; run 'ingress.sh install' first." >&2; exit 1; }

  echo "Enabling snippet annotations on the ingress-nginx controller..."
  kubectl -n ingress-nginx patch configmap ingress-nginx-controller --type merge \
    -p '{"data":{"allow-snippet-annotations":"true","annotations-risk-level":"Critical"}}'

  # allow-snippet-annotations is read at startup, so restart the controller and wait for it to be
  # ready before any Ingress carrying a snippet is applied.
  kubectl -n ingress-nginx rollout restart deployment/ingress-nginx-controller
  kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=240s
  echo "Snippet annotations enabled."
}

case "${1:-}" in
  install) install ;;
  allow-snippets) allow_snippets ;;
  *) echo "usage: ingress.sh {install|allow-snippets}" >&2; exit 2 ;;
esac
