#!/usr/bin/env bash
# Scaffold a new pattern from patterns/_template.
#
# Usage: scripts/new-pattern.sh <slug>
# Example: scripts/new-pattern.sh single-gateway
set -euo pipefail

NAME="${1:?usage: new-pattern.sh <slug>}"
# Enforce a kebab-case slug so it is a clean directory name and docs URL segment.
[[ "$NAME" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || {
  echo "slug must be kebab-case (lowercase, digits, hyphens): got '$NAME'" >&2; exit 2; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT_DIR}/patterns/_template"
DEST="${ROOT_DIR}/patterns/${NAME}"

[[ -d "$SRC" ]] || { echo "missing scaffold: patterns/_template" >&2; exit 2; }
[[ -e "$DEST" ]] && { echo "already exists: patterns/${NAME}" >&2; exit 2; }

cp -R "$SRC" "$DEST"
# Fill the __PATTERN__ placeholder with the slug.
grep -rl '__PATTERN__' "$DEST" 2>/dev/null | while read -r f; do
  sed -i "s/__PATTERN__/${NAME}/g" "$f"
done

echo "Created patterns/${NAME}."
echo "Next:"
echo "  1. Vendor the charts it needs:  scripts/sync-charts.sh ${NAME} <chart>..."
echo "  2. Edit patterns/${NAME}/meta.yaml (title, category, order, summary, status)."
echo "  3. Fill in patterns/${NAME}/README.md and the deploy/undeploy recipes in the Makefile."
echo "  4. Add a CI caller: cp an existing .github/workflows/<pattern>.yml and set the paths filter."
