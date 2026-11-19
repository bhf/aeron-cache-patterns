#!/usr/bin/env bash
# Vendor upstream Helm charts into a pattern's charts/ directory, pinned to a commit.
#
# Each pattern is self-contained: it carries its own copy of exactly the charts it deploys.
# This script copies them from the upstream aeron-cache repo and records provenance
# (repo + commit SHA + chart versions) in charts/VENDOR.lock so drift is auditable.
#
# Usage:
#   scripts/sync-charts.sh <pattern> <chart> [<chart> ...]
# Example:
#   scripts/sync-charts.sh monolith aeroncache-monolith
#   scripts/sync-charts.sh single-gateway aeroncache-cluster aeroncache-http \
#     aeroncache-ws aeroncache-sse aeroncache-gateway
#
# Env:
#   UPSTREAM_REPO  (default https://github.com/bhf/aeron-cache.git)
#   UPSTREAM_REF   (default main)   branch, tag, or commit to vendor from
set -euo pipefail

PATTERN="${1:?usage: sync-charts.sh <pattern> <chart>...}"; shift
[[ $# -ge 1 ]] || { echo "need at least one chart name" >&2; exit 2; }

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/bhf/aeron-cache.git}"
UPSTREAM_REF="${UPSTREAM_REF:-main}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATTERN_DIR="${ROOT_DIR}/patterns/${PATTERN}"
DEST="${PATTERN_DIR}/charts"
[[ -d "$PATTERN_DIR" ]] || { echo "no such pattern: patterns/${PATTERN}" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Cloning ${UPSTREAM_REPO} @ ${UPSTREAM_REF}..."
if ! git clone --quiet --depth 1 --branch "$UPSTREAM_REF" "$UPSTREAM_REPO" "$TMP/upstream" 2>/dev/null; then
  # --branch doesn't accept a raw commit SHA; fall back to a full clone + checkout.
  git clone --quiet "$UPSTREAM_REPO" "$TMP/upstream"
  git -C "$TMP/upstream" checkout --quiet "$UPSTREAM_REF"
fi
SHA="$(git -C "$TMP/upstream" rev-parse HEAD)"

mkdir -p "$DEST"
for chart in "$@"; do
  src="$TMP/upstream/k8s/helm/${chart}"
  [[ -d "$src" ]] || { echo "chart not found upstream: k8s/helm/${chart}" >&2; exit 2; }
  echo "Vendoring ${chart} -> patterns/${PATTERN}/charts/${chart}"
  rm -rf "${DEST:?}/${chart}"
  cp -R "$src" "${DEST}/${chart}"
  # The upstream per-chart Makefile drives helm with upstream's own conventions; this repo
  # drives helm from the pattern Makefile instead, so drop it to avoid confusion.
  rm -f "${DEST}/${chart}/Makefile"
done

# Record provenance so we can diff against upstream later (see .github/workflows/chart-drift.yml).
{
  echo "# Vendored charts — managed by scripts/sync-charts.sh. Do not hand-edit chart contents;"
  echo "# re-run the script to refresh, then review the diff."
  echo "upstream_repo: ${UPSTREAM_REPO}"
  echo "upstream_ref:  ${UPSTREAM_REF}"
  echo "upstream_sha:  ${SHA}"
  echo "synced_at:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "charts:"
  for chart in "$@"; do
    ver="$(awk '/^version:/{print $2; exit}' "${DEST}/${chart}/Chart.yaml")"
    echo "  - name: ${chart}"
    echo "    version: ${ver:-unknown}"
  done
} > "${DEST}/VENDOR.lock"

echo "Wrote patterns/${PATTERN}/charts/VENDOR.lock (upstream sha ${SHA:0:12})"
