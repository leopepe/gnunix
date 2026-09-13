#!/bin/sh
# validate-minimal.sh <vm-name|disk-image>
# Boots a gnunix-minimal image and runs Phase 3 post-boot checks.
# Exits 0 on success; non-zero with a one-line reason on failure.
#
# Per ADR-021: supports both Tart (local Mac) and disk images (CI).

set -eu
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}

VM_OR_IMG="${1:-}"
[ -z "$VM_OR_IMG" ] && { echo "usage: $0 <vm-name|disk-image>" >&2; exit 1; }

# Shared post-boot assertions, defined once and run by both paths. They used
# to be two near-identical copies that had already drifted.
MINIMAL_CHECKS='
  set -e
  echo "uname: $(uname -a)"

   # Nix itself. Exported explicitly because this is not a login shell, so
   # /etc/profile has not run -- see the separate login-shell check below,
   # which is the one that actually exercises the profile.d wiring.
  export PATH="/nix/var/nix/profiles/default/bin:$PATH"
  command -v nix       >/dev/null || { echo "FAIL: nix not on PATH"; exit 2; }
  command -v nix-store >/dev/null || { echo "FAIL: nix-store not on PATH"; exit 3; }
  nix --version
  nix-store --version

  pidof nix-daemon >/dev/null \
     || { echo "FAIL: nix-daemon not running (rc.nix-daemon enabled?)"; exit 4; }
  nix-store -q --hash /nix/var/nix/profiles/default >/dev/null \
     || { echo "FAIL: nix-store cannot query the default profile"; exit 5; }

  getent passwd nixbld1  >/dev/null || { echo "FAIL: nixbld1 user missing";  exit 6; }
  getent passwd nixbld32 >/dev/null || { echo "FAIL: nixbld32 user missing"; exit 7; }
  getent group  nixbld   >/dev/null || { echo "FAIL: nixbld group missing";  exit 8; }

   # --- system profile (ADR-025, issue #161) ---
   #
   # The logging, cron and process-inspection userland is declared in
   # nix/minimal.nix and installed as the system profile rather than
   # compiled into the LFS base. Everything below would have passed
   # vacuously before that move, so each check names what it is proving.

   # 9. the profile exists and is a symlink nix-env --set can roll back.
  [ -L /nix/var/nix/profiles/system ] \
     || { echo "FAIL: /nix/var/nix/profiles/system is not a symlink"; exit 9; }

   # 10. it actually contains the daemons. buildEnv drops any subtree
   #     missing from pathsToLink without erroring, so a profile can build
   #     green and be empty of everything that matters.
  for b in syslogd crond; do
    [ -x "/nix/var/nix/profiles/system/sbin/$b" ] \
      || [ -x "/nix/var/nix/profiles/system/bin/$b" ] \
      || { echo "FAIL: $b missing from the system profile"; exit 10; }
  done

   # 11. and they are running -- rc.syslogd and rc.crond resolve them by
   #     absolute path out of the profile, which is the whole point.
  pidof syslogd >/dev/null || { echo "FAIL: syslogd not running"; exit 11; }
  pidof crond   >/dev/null || { echo "FAIL: crond not running";   exit 12; }

   # 12. a LOGIN shell sees the profile. This is the gap ADR-025 recorded
   #     and #161 closed: without /etc/profile.d/nix-system-profile.sh the
   #     packages are on disk and untypeable.
  bash -lc "command -v ps" >/dev/null \
     || { echo "FAIL: ps not on a login shell PATH"; exit 13; }

   # 13. and in the right ORDER. The users own profile must come first, so
   #     someone who installs their own build of a shipped tool gets theirs.
  LOGIN_PATH=$(bash -lc "printf %s \"\$PATH\"")
  case "$LOGIN_PATH" in
    *"/nix/var/nix/profiles/system/bin"*) ;;
    *) echo "FAIL: system profile not on the login PATH: $LOGIN_PATH"; exit 14 ;;
  esac
  SYS_POS=${LOGIN_PATH%%/nix/var/nix/profiles/system/bin*}
  case "$SYS_POS" in
    *"/usr/bin"*|*"/usr/sbin"*)
      echo "FAIL: system profile comes AFTER /usr/bin: $LOGIN_PATH"; exit 15 ;;
  esac

  pidof sshd >/dev/null || echo "WARN: sshd not running"
   # dbus is a gnunix-desktop package (nix/desktop.nix); never present here.
  echo "[validate-minimal] PASS"
'

if [ -f "$VM_OR_IMG" ]; then
     # === CI mode: the argument is a disk image, booted under qemu. ===
     #
     # This path used to require `tart` and, finding none on a Linux
     # runner, print "no Tart or QEMU available; skipping test" and exit 0.
     # The test-minimal job has therefore been green without booting
     # anything. It now mirrors scripts/validate-boot.sh, which had the
     # qemu path all along.
    . "$REPO_ROOT/scripts/vm-helpers.sh"
    VM_DRIVER=qemu
    export VM_DRIVER

    command -v qemu-system-aarch64 >/dev/null || {
        echo "FAIL: qemu-system-aarch64 not installed" >&2
        exit 1
    }

    echo "[validate-minimal] CI mode — testing disk image: $VM_OR_IMG"

    WORK=$(mktemp -d)
    VM="gnunix-minimal-test-$$"
     # Keep console.log and qemu.log for the failure artifact; drop only the
     # multi-GB disk copy. Same reasoning as validate-boot.sh.
    cleanup() {
        vm_stop "$VM" >/dev/null 2>&1 || true
        rm -f "$(vm_dir_path "$VM")/disk.img" \
              "$(vm_dir_path "$VM")/efi-vars.fd" 2>/dev/null || true
        rm -rf "$WORK"
    }
    trap cleanup EXIT

    IMG="$VM_OR_IMG"
    case "$IMG" in
        *.zst)
            OUT="$WORK/test.img"
            echo "[validate-minimal] decompressing $IMG -> $OUT"
            zstd -d -c "$IMG" > "$OUT"
            IMG="$OUT"
            ;;
    esac

     # Private copy, so the artifact under test is never mutated by a boot.
    vm_import_raw "$IMG" "$VM"

     # The image ships with root locked and no authorized_keys, which is
     # correct for a published artifact. Give the COPY an ephemeral key.
    ssh-keygen -t ed25519 -N '' -q -f "$WORK/id" -C "gnunix-minimal-test"
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

    echo "[validate-minimal] booting disk image under qemu"
    vm_run "$VM" --detach

    echo "[validate-minimal] waiting for ssh"
    if ! vm_wait_ssh "$VM" root; then
        echo "FAIL: ssh did not become available within ${VM_SSH_TIMEOUT}s"
        dump_console
        exit 1
    fi

    echo "[validate-minimal] running smoke checks"
    if ! vm_ssh "$VM" root sh -c "$MINIMAL_CHECKS"; then
        echo "FAIL: smoke checks failed"
        dump_console
        exit 1
    fi

    vm_stop "$VM" >/dev/null 2>&1 || true
    exit 0
fi

# === Tart path (local Mac). ===
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
vm_ssh "$VM" root sh -c "$MINIMAL_CHECKS"
