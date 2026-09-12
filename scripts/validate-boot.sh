#!/bin/sh
# validate-boot.sh <vm-name|disk-image>
# Boots a gnunix-base image and runs basic post-boot checks.
# Exits 0 on success; non-zero with a one-line reason on failure.
#
# Per ADR-021: supports both Tart (local Mac) and disk images (CI).
# Tart path: boots a named Tart VM.
# CI path: the argument is a path to a .img file.

set -eu
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}

VM_OR_IMG="${1:-}"
[ -z "$VM_OR_IMG" ] && { echo "usage: $0 <vm-name|disk-image>" >&2; exit 1; }

# Detect mode: if the argument is a path to a .img file, use CI mode.
# Otherwise, treat it as a Tart VM name.
# Shared post-boot assertions. Phase 2 minimum: sshd + a default route.
# dbus and elogind are deferred (they need the Python/meson bootstrap), so
# they warn rather than fail.
SMOKE_CHECKS='
  set -e
  echo "uname: $(uname -a)"
  echo "uptime: $(uptime)"
  pidof sshd          >/dev/null || { echo "FAIL: sshd not running"; exit 4; }
  ip route get 1.1.1.1 >/dev/null 2>&1 || { echo "FAIL: no default route"; exit 5; }
  pidof dbus-daemon   >/dev/null || echo "WARN: dbus not running (deferred)"
  pidof elogind       >/dev/null || echo "WARN: elogind not running (deferred)"
  echo "[validate] PASS"
'

if [ -f "$VM_OR_IMG" ]; then
    # CI mode: the argument is a disk image, booted under qemu.
    #
    # Per ADR-021 this runs on a GitHub-hosted arm64 runner, which has no
    # /dev/kvm — so the guest runs under TCG emulation and a full boot
    # takes minutes, not seconds. VM_SSH_TIMEOUT reflects that.
    . "$REPO_ROOT/scripts/vm-helpers.sh"
    VM_DRIVER=qemu
    export VM_DRIVER

    command -v qemu-system-aarch64 >/dev/null || {
        echo "FAIL: qemu-system-aarch64 not installed" >&2
        exit 1
    }

    echo "[validate] CI mode — testing disk image: $VM_OR_IMG"

    WORK=$(mktemp -d)
    VM="gnunix-boot-test-$$"
    trap 'vm_delete "$VM" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

    IMG="$VM_OR_IMG"
    case "$IMG" in
        *.zst)
            OUT="$WORK/test.img"
            echo "[validate] decompressing $IMG -> $OUT"
            zstd -d -c "$IMG" > "$OUT"
            IMG="$OUT"
            ;;
    esac

    # Private copy, so the artifact under test is never mutated by a boot.
    vm_import_raw "$IMG" "$VM"

    # The image ships with root locked and no authorized_keys, which is
    # correct for a published artifact. Give the COPY an ephemeral key so
    # the test can log in; see scripts/inject-test-key.sh.
    ssh-keygen -t ed25519 -N '' -q -f "$WORK/id" -C "gnunix-boot-test"
    sudo "$REPO_ROOT/scripts/inject-test-key.sh" \
        "$(vm_disk_path "$VM")" "$WORK/id.pub"
    VM_SSH_KEY="$WORK/id"
    export VM_SSH_KEY

    dump_console() {
        con=$(vm_console_path "$VM")
        echo "--- guest console (last 60 lines of $con) ---" >&2
        tail -60 "$con" 2>/dev/null || echo "(no console output captured)" >&2
        echo "--- qemu stderr ---" >&2
        tail -20 "$(vm_dir_path "$VM")/qemu.log" 2>/dev/null || true
        echo "---------------------------------------------" >&2
    }

    echo "[validate] booting disk image under qemu"
    vm_run "$VM" --detach

    echo "[validate] waiting for ssh"
    if ! vm_wait_ssh "$VM" root; then
        echo "FAIL: ssh did not become available within ${VM_SSH_TIMEOUT}s"
        dump_console
        exit 1
    fi

    echo "[validate] running smoke checks"
    if ! vm_ssh "$VM" root sh -c "$SMOKE_CHECKS"; then
        echo "FAIL: smoke checks failed"
        dump_console
        exit 1
    fi

    vm_stop "$VM" >/dev/null 2>&1 || true
    exit 0
fi

# Tart path (local Mac).
. "$REPO_ROOT/scripts/vm-helpers.sh"
VM="$VM_OR_IMG"

echo "[validate] starting $VM"
vm_run --no-graphics "$VM" >/dev/null 2>&1 &
TART_PID=$!
trap 'vm_stop "$VM" >/dev/null 2>&1 || true; kill $TART_PID 2>/dev/null || true' EXIT

echo "[validate] waiting for ssh"
if ! vm_wait_ssh "$VM" root; then
  echo "FAIL: ssh did not become available"
  exit 1
fi

echo "[validate] running smoke checks"
vm_ssh "$VM" root sh -c "$SMOKE_CHECKS"
