#!/bin/sh
# tests/base/boot-smoke.sh <vm-name>
# Phase 2 acceptance test: VM boots, services start, network works,
# we can log in via ssh and the rc.d dispatcher reached the end of rc.M.

set -eu

# Resolve $0 through any compat symlink at the old path
# (tests/boot-smoke.sh → tests/base/boot-smoke.sh). POSIX-safe;
# `readlink` without `-f` works on both macOS and Linux. Tracked in
# the follow-up issue referenced from tests/CLAUDE.md.
SCRIPT=$0
while [ -L "$SCRIPT" ]; do
  TARGET=$(readlink "$SCRIPT")
  case "$TARGET" in
    /*) SCRIPT=$TARGET ;;
    *)  SCRIPT=$(dirname "$SCRIPT")/$TARGET ;;
  esac
done
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$SCRIPT")/../.." && pwd)}

exec "$REPO_ROOT/scripts/validate-boot.sh" "$@"
