#!/usr/bin/env bash
# Run gitleaks over the working tree.
#
# `check-gitleaks-config' asserts the CONFIG is non-trivial. This runs the
# scanner. Those are different claims, and the repository previously only made
# the first one -- which is the same shape of mistake as a lint rule that passes
# by matching its own comments.
#
# --no-git because this scans the tree as it stands, including changes not yet
# staged. CI scans history separately.
set -euo pipefail

command -v gitleaks >/dev/null || {
  echo "error: gitleaks is not installed; see tools.lock for the pinned version" >&2
  exit 1
}

gitleaks detect --no-git --config .gitleaks.toml --redact --exit-code 1 "$@" >/dev/null 2>&1 || {
  echo "error: gitleaks found a secret. Re-run for detail:" >&2
  echo "  gitleaks detect --no-git --config .gitleaks.toml --redact -v" >&2
  exit 1
}
echo "OK: no secrets found in the working tree"
