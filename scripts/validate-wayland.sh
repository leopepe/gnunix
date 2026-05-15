#!/bin/sh
# validate-wayland.sh <vm-name>
# Boots an gnunix-desktop Tart image and runs Phase 4 post-boot checks.
# Asserts that the system services are installed, supervised, and the
# bits required for a Wayland session are in place. Does NOT attempt to
# actually render a frame — that's a separate testing problem (ADR-009).

set -eu
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$REPO_ROOT/scripts/tart-helpers.sh"

VM=${1:-}
[ -z "$VM" ] && { echo "usage: $0 <vm-name>" >&2; exit 1; }

echo "[validate-wayland] starting $VM"
tart run --no-graphics "$VM" >/dev/null 2>&1 &
TART_PID=$!
trap 'tart stop "$VM" >/dev/null 2>&1 || true; kill $TART_PID 2>/dev/null || true' EXIT

echo "[validate-wayland] waiting for ssh"
if ! tart_wait_ssh "$VM" root; then
  echo "FAIL: ssh did not become available within 120s"
  exit 1
fi

echo "[validate-wayland] running smoke checks"
tart_ssh "$VM" root sh -c '
  set -e
  echo "uname: $(uname -a)"
  SP=/nix/var/nix/profiles/system

  # 1. system-profile binaries are present.
  #    Per ADR-020: Hyprland (capital H) replaces sway as the compositor.
  for bin in dbus-daemon greetd tuigreet Hyprland foot waybar; do
    [ -x "$SP/bin/$bin" ] \
      || { echo "FAIL: missing $SP/bin/$bin"; exit 2; }
  done
  # elogind on nixpkgs ships at libexec/elogind (single file), not bin/.
  [ -x "$SP/libexec/elogind" ] || [ -x "$SP/bin/elogind" ] \
    || { echo "FAIL: elogind binary not found under $SP"; exit 2; }

  # 2. rc.d scripts are present AND enabled (executable).
  for rc in rc.dbus rc.elogind rc.greetd; do
    [ -x "/etc/rc.d/$rc" ] \
      || { echo "FAIL: /etc/rc.d/$rc not enabled"; exit 3; }
  done

  # 3. daemons running. elogind renames itself to "elogind-daemon" after
  #    --daemon double-fork — match both.
  pidof dbus-daemon >/dev/null \
    || { echo "FAIL: dbus-daemon not running"; exit 4; }
  pidof elogind-daemon >/dev/null || pidof elogind >/dev/null \
    || { echo "FAIL: elogind not running"; exit 5; }
  pidof greetd >/dev/null \
    || { echo "FAIL: greetd not running"; exit 6; }

  # 4. unprivileged user exists with expected groups.
  getent passwd user >/dev/null \
    || { echo "FAIL: login user missing"; exit 7; }
  id -nG user | tr " " "\n" | grep -qx video \
    || { echo "FAIL: user not in video group"; exit 8; }

  # 5. virtio-gpu DRM device present (warns rather than fails: a kernel
  #    config drift could nuke /dev/dri without invalidating the rest of
  #    the install, and we want the operator to see that explicitly).
  if [ ! -e /dev/dri/card0 ]; then
    echo "WARN: /dev/dri/card0 missing (no DRM device — check CONFIG_DRM_VIRTIO_GPU)"
  fi

  # 6. login1 D-Bus name is reachable (elogind registered with dbus).
  if command -v dbus-send >/dev/null; then
    dbus-send --system --print-reply --dest=org.freedesktop.DBus \
      /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null \
      | grep -q "org.freedesktop.login1" \
      || echo "WARN: org.freedesktop.login1 not on the system bus (elogind not registered?)"
  fi

  echo "[validate-wayland] PASS"
'
