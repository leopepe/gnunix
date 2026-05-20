#!/bin/sh
# validate-wayland.sh <vm-name|disk-image>
# Boots an gnunix-desktop image and runs Phase 4 post-boot checks.
# Asserts that the system services are installed, supervised, and the
# bits required for a Wayland session are in place. Does NOT attempt to
# actually render a frame — that's a separate testing problem (ADR-009).
#
# Per ADR-021: supports both Tart (local Mac) and disk images (CI).

set -eu
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}

VM_OR_IMG="${1:-}"
[ -z "$VM_OR_IMG" ] && { echo "usage: $0 <vm-name|disk-image>" >&2; exit 1; }

if [ -f "$VM_OR_IMG" ]; then
      # CI mode: disk image path.
    . "$REPO_ROOT/scripts/vm-helpers.sh"
    VM_DRIVER=qvm
    export VM_DRIVER

    echo "[validate-wayland] CI mode — testing disk image: $VM_OR_IMG"

    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT

    IMG="$VM_OR_IMG"
    case "$IMG" in
        *.img.zst)
      OUT="$WORK/test.img"
      echo "[validate-wayland] decompressing $IMG → $OUT"
      zstd -d -c "$IMG" > "$OUT"
      IMG="$OUT"
          ;;
    esac

    if command -v tart >/dev/null 2>&1; then
      TART_VM="gnunix-desktop-test-$$"
      tart delete "$TART_VM" 2>/dev/null || true
      tart create --linux --disk-size 20 "$TART_VM" 2>/dev/null || true
      TART_DIR="$HOME/.tart/vms/$TART_VM"
      cp "$IMG" "$TART_DIR/disk.img" 2>/dev/null || true
      tart run --no-graphics "$TART_VM" >/dev/null 2>&1 &
      TART_PID=$!
      trap 'tart stop "$TART_VM" >/dev/null 2>&1 || true; kill $TART_PID 2>/dev/null || true; tart delete "$TART_VM" 2>/dev/null || true' EXIT

      if tart_wait_ssh "$TART_VM" root 2>/dev/null; then
        echo "[validate-wayland] running smoke checks"
        tart_ssh "$TART_VM" root sh -c '
          set -e
          echo "uname: $(uname -a)"
          SP=/nix/var/nix/profiles/system

            # 1. system-profile binaries are present.
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

            # 3. daemons running.
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

            # 5. virtio-gpu DRM device present.
          if [ ! -e /dev/dri/card0 ]; then
            echo "FAIL: /dev/dri/card0 missing — virtio-gpu did not load."
            exit 9
          fi

            # 6. login1 D-Bus name is reachable.
          if command -v dbus-send >/dev/null; then
            dbus-send --system --print-reply --dest=org.freedesktop.DBus \
              /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null \
              | grep -q "org.freedesktop.login1" \
              || echo "WARN: org.freedesktop.login1 not on the system bus (elogind not registered?)"
          fi

          echo "[validate-wayland] PASS"
          '
        tart stop "$TART_VM" >/dev/null 2>&1 || true
        tart delete "$TART_VM" >/dev/null 2>&1 || true
        exit 0
      else
        echo "FAIL: ssh did not become available"
        tart stop "$TART_VM" >/dev/null 2>&1 || true
        tart delete "$TART_VM" >/dev/null 2>&1 || true
        exit 1
      fi
    else
      echo "[validate-wayland] WARN: no Tart or QEMU available; skipping test"
      exit 0
    fi
fi

# Tart path (local Mac).
. "$REPO_ROOT/scripts/vm-helpers.sh"
VM="$VM_OR_IMG"

echo "[validate-wayland] starting $VM"
vm_run --no-graphics "$VM" >/dev/null 2>&1 &
TART_PID=$!
trap 'vm_stop "$VM" >/dev/null 2>&1 || true; kill $TART_PID 2>/dev/null || true' EXIT

echo "[validate-wayland] waiting for ssh"
if ! vm_wait_ssh "$VM" root; then
  echo "FAIL: ssh did not become available within 120s"
  exit 1
fi

echo "[validate-wayland] running smoke checks"
vm_ssh "$VM" root sh -c '
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
    #     --daemon double-fork — match both.
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

    # 5. virtio-gpu DRM device present. Hard fail now (was WARN): the
    #    explicit /etc/modules-load.d/virtio.conf + the /sbin/modprobe
    #    symlink shipped by install-gnunix-desktop.sh should make this
    #    reliable. A missing device means MODALIAS coldplug or rc.modules
    #    is silently broken — and every Wayland compositor bails at
    #    wlroots DRM init without it.
  if [ ! -e /dev/dri/card0 ]; then
    echo "FAIL: /dev/dri/card0 missing — virtio-gpu did not load."
    echo "  Check: /sbin/modprobe exists, /etc/modules-load.d/virtio.conf exists,"
    echo "         and rc.modules ran at boot."
    exit 9
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
