#!/usr/bin/env bash
# Cluster lifecycle abstraction used by common/pattern.mk.
#
# Local default is minikube; CI sets CLUSTER=kind. Both pull the public ghcr.io/<owner>/aeroncache-*
# images directly, so there is no image-load step either way.
#
# Usage: cluster.sh <function>      e.g. cluster.sh cluster_up
# Env:
#   CLUSTER        minikube | kind   (default minikube)
#   CLUSTER_NAME   profile / cluster name (default aeroncache-patterns)
#   KIND_CONFIG    optional path to a kind config (only used when CLUSTER=kind)
#   MINIKUBE_ARGS  optional extra args for `minikube start`
#   AUTOSCALE      true installs metrics-server (HPAs need it); set by pattern.mk from make
#   METRICS_SERVER true forces metrics-server install even without AUTOSCALE
set -euo pipefail

CLUSTER="${CLUSTER:-minikube}"
CLUSTER_NAME="${CLUSTER_NAME:-aeroncache-patterns}"
METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-v0.7.2}"

# metrics-server powers HorizontalPodAutoscalers (and `kubectl top`). Installed only when autoscaling
# is requested so the default/CI path stays lean. Idempotent: re-running just re-applies.
ensure_metrics_server() {
  [[ "${AUTOSCALE:-false}" == "true" || "${METRICS_SERVER:-false}" == "true" ]] || return 0
  case "$CLUSTER" in
    minikube)
      echo "Enabling metrics-server (minikube addon)..."
      minikube addons enable metrics-server -p "$CLUSTER_NAME"
      ;;
    kind)
      echo "Installing metrics-server ${METRICS_SERVER_VERSION} (kind)..."
      kubectl apply -f \
        "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"
      # kind nodes serve kubelet metrics with self-signed certs; let metrics-server trust them.
      kubectl patch -n kube-system deployment metrics-server --type=json \
        -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
      kubectl -n kube-system rollout status deployment metrics-server --timeout=120s
      ;;
  esac
}

cluster_up() {
  case "$CLUSTER" in
    minikube)
      if minikube status -p "$CLUSTER_NAME" >/dev/null 2>&1; then
        echo "minikube profile '$CLUSTER_NAME' is already running."
      else
        echo "Starting minikube profile '$CLUSTER_NAME'..."
        # shellcheck disable=SC2086
        minikube start -p "$CLUSTER_NAME" ${MINIKUBE_ARGS:-}
      fi
      kubectl config use-context "$CLUSTER_NAME" >/dev/null
      ;;
    kind)
      if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
        echo "kind cluster '$CLUSTER_NAME' already exists."
      elif [[ -n "${KIND_CONFIG:-}" && -f "${KIND_CONFIG}" ]]; then
        kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG"
      else
        kind create cluster --name "$CLUSTER_NAME"
      fi
      kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null
      ;;
    *)
      echo "Unknown CLUSTER '$CLUSTER' (expected minikube|kind)." >&2
      exit 2
      ;;
  esac
  ensure_metrics_server
}

cluster_down() {
  case "$CLUSTER" in
    minikube) minikube delete -p "$CLUSTER_NAME" || true ;;
    kind)     kind delete cluster --name "$CLUSTER_NAME" || true ;;
    *) echo "Unknown CLUSTER '$CLUSTER'." >&2; exit 2 ;;
  esac
}

if [[ $# -lt 1 ]]; then
  echo "usage: cluster.sh <cluster_up|cluster_down>" >&2
  exit 2
fi
"$@"
