#!/bin/sh
# tests/wayland-session.sh <vm-name>
# Phase 4 acceptance test: boot gnunix-desktop-<ver>, verify dbus + elogind +
# greetd are installed and running, and the login user is provisioned.
#
# This is a "components present and supervised" test. Actually rendering a
# Wayland frame from CI is out of scope here (tracked in docs/TODO.md and
# ADR-009 "Out of scope").

set -eu
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
exec "$REPO_ROOT/scripts/validate-wayland.sh" "$@"
