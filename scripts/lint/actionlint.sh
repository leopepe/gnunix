#!/bin/sh
# scripts/lint/actionlint.sh
#
# Wrapper that exports SHELLCHECK_OPTS before exec'ing actionlint, so
# the embedded shellcheck runs at the same severity threshold as the
# standalone shellcheck job (and as the actionlint job in
# .github/workflows/pr-lint.yml).
#
# Why a wrapper at all: pre-commit's hook schema has no `env:` key, so
# we can't pass SHELLCHECK_OPTS to the upstream rhysd/actionlint hook
# directly. .shellcheckrc can't help either — its grammar doesn't
# include `severity=`. The wrapper is the smallest piece that gives
# us parity with CI.
#
# Invoked by:
#   - .pre-commit-config.yaml (local pre-commit hook for actionlint)
#   - manually: scripts/lint/actionlint.sh [args]

set -eu

export SHELLCHECK_OPTS="-S warning"
exec actionlint "$@"
