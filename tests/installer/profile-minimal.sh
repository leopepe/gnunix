#!/bin/sh
# tests/installer/profile-minimal.sh
# Installer acceptance test for the `minimal` profile.
#
# Drives gnunix-installer unattended → target disk → boot installed
# system → run universal + minimal-specific assertions. Exits 0 on
# success.

set -eu
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
exec "$REPO_ROOT/scripts/run-installer-test.sh" minimal
