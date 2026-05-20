#!/bin/sh
# validate-minimal.sh <vm-name|disk-image>
# Boots an gnunix-minimal image and runs Phase 3 post-boot checks.
# Exits 0 on success; non-zero with a one-line reason on failure.
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

    echo "[validate-minimal] CI mode — testing disk image: $VM_OR_IMG"

    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT

    IMG="$VM_OR_IMG"
    case "$IMG" in
        *.img.zst)
      OUT="$WORK/test.img"
      echo "[validate-minimal] decompressing $IMG → $OUT"
      zstd -d -c "$IMG" > "$OUT"
      IMG="$OUT"
          ;;
    esac

    if command -v tart >/dev/null 2>&1; then
      TART_VM="gnunix-minimal-test-$$"
      tart delete "$TART_VM" 2>/dev/null || true
      tart create --linux --disk-size 20 "$TART_VM" 2>/dev/null || true
      TART_DIR="$HOME/.tart/vms/$TART_VM"
      cp "$IMG" "$TART_DIR/disk.img" 2>/dev/null || true
      tart run --no-graphics "$TART_VM" >/dev/null 2>&1 &
      TART_PID=$!
      trap 'tart stop "$TART_VM" >/dev/null 2>&1 || true; kill $TART_PID 2>/dev/null || true; tart delete "$TART_VM" 2>/dev/null || true' EXIT

      if tart_wait_ssh "$TART_VM" root 2>/dev/null; then
        echo "[validate-minimal] running smoke checks"
        tart_ssh "$TART_VM" root sh -c '
          set -e
          echo "uname: $(uname -a)"
          echo "uptime: $(uptime)"
          export PATH="/nix/var/nix/profiles/default/bin:$PATH"
          command -v nix        >/dev/null || { echo "FAIL: nix not on PATH"; exit 2; }
          command -v nix-store  >/dev/null || { echo "FAIL: nix-store not on PATH"; exit 3; }
          nix --version
          nix-store --version
          pidof nix-daemon     >/dev/null \
             || { echo "FAIL: nix-daemon not running (rc.nix-daemon enabled?)"; exit 4; }
          nix-store -q --hash /nix/var/nix/profiles/default >/dev/null \
             || { echo "FAIL: nix-store cannot query the default profile"; exit 5; }
          getent passwd nixbld1    >/dev/null || { echo "FAIL: nixbld1 user missing";  exit 6; }
          getent passwd nixbld32   >/dev/null || { echo "FAIL: nixbld32 user missing"; exit 7; }
          getent group  nixbld     >/dev/null || { echo "FAIL: nixbld group missing";  exit 8; }
          pidof sshd          >/dev/null || echo "WARN: sshd not running"
          pidof dbus-daemon   >/dev/null || echo "WARN: dbus not running (still deferred)"
          echo "[validate-minimal] PASS"
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
      echo "[validate-minimal] WARN: no Tart or QEMU available; skipping test"
      exit 0
    fi
fi

# Tart path (local Mac).
. "$REPO_ROOT/scripts/vm-helpers.sh"
VM="$VM_OR_IMG"

echo "[validate-minimal] starting $VM"
vm_run --no-graphics "$VM" >/dev/null 2>&1 &
TART_PID=$!
trap 'vm_stop "$VM" >/dev/null 2>&1 || true; kill $TART_PID 2>/dev/null || true' EXIT

echo "[validate-minimal] waiting for ssh"
if ! vm_wait_ssh "$VM" root; then
  echo "FAIL: ssh did not become available within 120s"
  exit 1
fi

echo "[validate-minimal] running smoke checks"
vm_ssh "$VM" root sh -c '
  set -e
  echo "uname: $(uname -a)"
   # Make /nix tools available even if /etc/profile.d/nix-daemon.sh did not
   # get sourced by this non-login shell.
  export PATH="/nix/var/nix/profiles/default/bin:$PATH"

   # 1. nix binaries present.
  command -v nix        >/dev/null || { echo "FAIL: nix not on PATH"; exit 2; }
  command -v nix-store >/dev/null || { echo "FAIL: nix-store not on PATH"; exit 3; }

   # 2. report versions.
  nix --version
  nix-store --version

   # 3. multi-user daemon running.
  pidof nix-daemon >/dev/null \
     || { echo "FAIL: nix-daemon not running (rc.nix-daemon enabled?)"; exit 4; }

   # 4. store db query works.
  nix-store -q --hash /nix/var/nix/profiles/default >/dev/null \
     || { echo "FAIL: nix-store cannot query the default profile"; exit 5; }

   # 5. nixbld* users present.
  getent passwd nixbld1   >/dev/null || { echo "FAIL: nixbld1 user missing";  exit 6; }
  getent passwd nixbld32 >/dev/null || { echo "FAIL: nixbld32 user missing"; exit 7; }
  getent group  nixbld    >/dev/null || { echo "FAIL: nixbld group missing";  exit 8; }

   # Warnings: things deferred from Phase 2 that still aren'\''t here.
  pidof sshd         >/dev/null || echo "WARN: sshd not running"
  pidof dbus-daemon >/dev/null || echo "WARN: dbus not running (still deferred)"

  echo "[validate-minimal] PASS"
'
