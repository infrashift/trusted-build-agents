# Operational entrypoint. Invoked as `make -f Ops.mk <target>', never as a bare
# `Makefile': the repository root is a build CONTEXT, and a Makefile there would
# be copied into every image built from it.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

ORG        := infrashift
REPO_NAME  := $(shell basename -s .git "$$(git config --get remote.origin.url 2>/dev/null || echo trusted-build-agents)")
REGISTRY   := ghcr.io/$(ORG)/$(REPO_NAME)
IMAGES     := $(shell jq -r '.images | keys[]' versions.json)

.DEFAULT_GOAL := validate

.PHONY: validate
validate: check-schema check-gitleaks-config scan-secrets check-no-orphan-rego lint-containerfiles lint-image-contract lint-docs lint-shell policy-test selftest
	@echo "OK: repository validation passed"

.PHONY: check-schema
check-schema:
	@python3 scripts/validate-schema.py

# A gitleaks config that scans for nothing reports a clean run, which is worse
# than no config at all because it looks like evidence. Assert both that the file
# is substantial and that it extends the default rule set.
.PHONY: check-gitleaks-config
check-gitleaks-config:
	@test -s .gitleaks.toml || { echo "error: .gitleaks.toml is empty" >&2; exit 1; }
	@test "$$(stat -c %s .gitleaks.toml)" -gt 64 || { echo "error: .gitleaks.toml is trivially small" >&2; exit 1; }
	@grep -q 'useDefault = true' .gitleaks.toml || { echo "error: .gitleaks.toml does not set useDefault = true" >&2; exit 1; }
	@echo "OK: gitleaks config is non-trivial"

# One policy file, one package. A second .rego that nothing imports is a rule set
# somebody wrote, believes is enforced, and is not.
# Asserting the config is non-trivial and RUNNING the scanner are different
# claims. Make both.
.PHONY: scan-secrets
scan-secrets:
	@bash scripts/scan-secrets.sh

.PHONY: check-no-orphan-rego
check-no-orphan-rego:
	@found=$$(find . -name '*.rego' -not -path './.git/*' | sort); \
	expected=$$'./.github/pdp/policies.rego\n./.github/pdp/policies_test.rego'; \
	if [ "$$found" != "$$expected" ]; then \
	  echo "error: unexpected .rego files:" >&2; echo "$$found" >&2; exit 1; fi
	@echo "OK: exactly one policy file and its tests"

.PHONY: lint-containerfiles
lint-containerfiles:
	@bash scripts/lint-containerfiles.sh

.PHONY: lint-image-contract
lint-image-contract:
	@bash scripts/lint-image-contract.sh

.PHONY: lint-docs
lint-docs:
	@bash scripts/lint-docs.sh

.PHONY: lint-shell
lint-shell:
	@shellcheck scripts/*.sh rootfs/*/usr/local/bin/*.sh
	@echo "OK: shellcheck clean"

.PHONY: policy-test
policy-test:
	@opa test .github/pdp/ --verbose --coverage --format json \
	  | jq -e '.coverage >= 85' >/dev/null \
	  || { echo "error: policy coverage is below the 85% floor" >&2; exit 1; }
	@echo "OK: policy tests pass at or above the coverage floor"

# A check that has never failed is a decoration. This applies a known-bad
# mutation for each rule and fails if the linter does not object.
.PHONY: selftest
selftest:
	@bash scripts/selftest-linters.sh

.PHONY: list-images
list-images:
	@for i in $(IMAGES); do \
	  printf '%-22s pool=%-18s %s\n' "$$i" \
	    "$$(jq -r --arg i "$$i" '.images[$$i].pool' versions.json)" \
	    "$(REGISTRY)/trusted/$$i"; \
	done

# Resolve every pin LIVE and compare it to what is recorded. A pin that no longer
# resolves is not necessarily wrong, but it is always worth knowing about before
# a build discovers it.
.PHONY: verify-pins
verify-pins:
	@bash scripts/verify-pins.sh

.PHONY: build
build:
	@test -n "$(IMAGE)" || { echo "usage: make -f Ops.mk build IMAGE=<name> [ARCH=amd64]" >&2; exit 1; }
	@bash scripts/build-leg.sh "$(IMAGE)" "$${ARCH:-amd64}"
