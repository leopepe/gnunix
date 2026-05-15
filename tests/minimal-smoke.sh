#!/bin/sh
# tests/minimal-smoke.sh <vm-name>
# Phase 3 acceptance test: boot gnunix-minimal-<ver>, verify nix is installed,
# the multi-user daemon is running, and a trivial nix store query works.

set -eu
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
exec "$REPO_ROOT/scripts/validate-minimal.sh" "$@"
