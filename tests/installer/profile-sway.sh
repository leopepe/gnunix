#!/bin/sh
# tests/installer/profile-sway.sh
# Installer acceptance test for the `desktop-sway` profile.

set -eu
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
exec "$REPO_ROOT/scripts/run-installer-test.sh" desktop-sway
