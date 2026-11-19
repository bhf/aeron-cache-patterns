# Aeron Cache Patterns — top-level convenience Makefile.
#
# Each pattern under patterns/<name>/ is self-contained and has its own Makefile. This
# top-level Makefile just lists patterns and delegates to them, so you can drive any
# pattern from the repo root:
#
#   make list
#   make up     PATTERN=monolith
#   make verify PATTERN=monolith
#   make down   PATTERN=monolith
#
# ...or cd into the pattern and run `make up` / `make verify` / `make down` directly.

PATTERNS := $(filter-out _template,$(notdir $(wildcard patterns/*)))

# Targets delegated to a single pattern (require PATTERN=<name>).
DELEGATED := up down deploy undeploy redeploy wait verify status logs cluster-up cluster-down

.DEFAULT_GOAL := help
.PHONY: help list doctor $(DELEGATED)

help: ## Show this help
	@echo "Aeron Cache Patterns"
	@echo
	@echo "Usage:"
	@echo "  make <target> PATTERN=<name>     drive one pattern (e.g. make up PATTERN=monolith)"
	@echo "  make list                        list available patterns"
	@echo "  make doctor                      check local tooling"
	@echo
	@echo "Patterns:"
	@for p in $(PATTERNS); do echo "  - $$p"; done
	@echo
	@echo "Per-pattern targets (need PATTERN=<name>): $(DELEGATED)"

list: ## List available patterns
	@for p in $(PATTERNS); do echo "$$p"; done

doctor: ## Check required local tooling (CLUSTER=kind to check for kind instead of minikube)
	@bash scripts/doctor.sh

$(DELEGATED): ## Delegate to a pattern: make <target> PATTERN=<name>
	@test -n "$(PATTERN)" || { echo "Set PATTERN=<name> (see 'make list')." >&2; exit 2; }
	@test -d "patterns/$(PATTERN)" || { echo "No such pattern: $(PATTERN) (see 'make list')." >&2; exit 2; }
	@$(MAKE) --no-print-directory -C patterns/$(PATTERN) $@
