#!/bin/sh
# tests/installer/profile-labwc.sh
# Installer acceptance test for the `desktop-labwc` profile.
# NOTE: requires network at test-time (labwc closure is pulled from
# cache.nixos.org during install).

set -eu
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
exec "$REPO_ROOT/scripts/run-installer-test.sh" desktop-labwc
