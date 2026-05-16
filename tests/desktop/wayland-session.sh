#!/bin/sh
# tests/desktop/wayland-session.sh <vm-name>
# Phase 4 acceptance test: boot gnunix-desktop-<ver>, verify dbus + elogind +
# greetd are installed and running, and the login user is provisioned.
#
# This is a "components present and supervised" test. Actually rendering a
# Wayland frame from CI is out of scope here (tracked in docs/TODO.md and
# ADR-009 "Out of scope").

set -eu

# Resolve $0 through any compat symlink at the old path
# (tests/wayland-session.sh → tests/desktop/wayland-session.sh). POSIX-safe;
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

exec "$REPO_ROOT/scripts/validate-wayland.sh" "$@"
