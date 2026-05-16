#!/bin/sh
# tests/minimal/minimal-smoke.sh <vm-name>
# Phase 3 acceptance test: boot gnunix-minimal-<ver>, verify nix is installed,
# the multi-user daemon is running, and a trivial nix store query works.

set -eu

# Resolve $0 through any compat symlink at the old path
# (tests/minimal-smoke.sh → tests/minimal/minimal-smoke.sh). POSIX-safe;
# `readlink` without `-f` works on both macOS and Linux. Tracked in the
# follow-up issue referenced from tests/CLAUDE.md.
SCRIPT=$0
while [ -L "$SCRIPT" ]; do
  TARGET=$(readlink "$SCRIPT")
  case "$TARGET" in
    /*) SCRIPT=$TARGET ;;
    *)  SCRIPT=$(dirname "$SCRIPT")/$TARGET ;;
  esac
done
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$SCRIPT")/../.." && pwd)}

exec "$REPO_ROOT/scripts/validate-minimal.sh" "$@"
