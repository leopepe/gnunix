#!/bin/sh
# tests/installer/profile-cosmic.sh
# Installer acceptance test for the `desktop-cosmic` profile (ADR-022).
#
# Drives gnunix-installer unattended → target disk → boot installed
# system → run universal + cosmic-specific assertions. Exits 0 on
# success.

set -eu
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
exec "$REPO_ROOT/scripts/run-installer-test.sh" cosmic
