#!/bin/sh
# tests/boot-smoke.sh <vm-name>
# Phase 2 acceptance test: VM boots, services start, network works,
# we can log in via ssh and the rc.d dispatcher reached the end of rc.M.

set -eu
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
exec "$REPO_ROOT/scripts/validate-boot.sh" "$@"
