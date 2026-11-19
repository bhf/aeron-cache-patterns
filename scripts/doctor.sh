#!/usr/bin/env bash
# Check that the local tooling a pattern needs is present.
# Local default cluster is minikube; set CLUSTER=kind to check for kind instead.
set -uo pipefail

CLUSTER="${CLUSTER:-minikube}"
req=(kubectl helm curl jq)
if [[ "$CLUSTER" == "kind" ]]; then req+=(kind); else req+=(minikube); fi

echo "Checking tooling (cluster: $CLUSTER)..."
missing=0
for t in "${req[@]}"; do
  if command -v "$t" >/dev/null 2>&1; then
    ver=$("$t" version --short 2>/dev/null | head -1 \
       || "$t" --version 2>/dev/null | head -1 \
       || echo present)
    printf "  \033[32m✔\033[0m %-9s %s\n" "$t" "$ver"
  else
    printf "  \033[31mx\033[0m %-9s MISSING\n" "$t"
    missing=1
  fi
done

if [[ "$missing" -ne 0 ]]; then
  echo
  echo "Some required tools are missing. Install them and re-run 'make doctor'." >&2
  exit 1
fi
echo "All good."
