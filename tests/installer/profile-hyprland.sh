#!/bin/sh
# tests/installer/profile-hyprland.sh
# Installer acceptance test for the `desktop-hyprland` profile.
# NOTE: requires network at test-time (Hyprland closure is pulled from
# cache.nixos.org during install).

set -eu
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
exec "$REPO_ROOT/scripts/run-installer-test.sh" desktop-hyprland
