#!/bin/sh
# Install an SSH public key into a RAW disk image's root filesystem.
#
# The gnunix-base artifact deliberately ships with no credentials:
# 04-finalize.sh locks the root password (`root:*:`) and nothing writes
# an authorized_keys. That is correct for a published image, and it also
# means the boot smoke test cannot log in to the thing it just built.
#
# So the key goes into the test's private COPY of the image, never into
# the artifact. The published image stays credential-free, and the boot
# path under test is still the real one (GRUB -> kernel -> sysvinit ->
# sshd), not a special test build.
#
# The Tart path does the equivalent at build time in tools/build-all.sh;
# doing it at build time in CI would bake a key into the release
# artifact, which is why this is a post-build step instead.
#
# Requires root: it loop-mounts the image's root partition.
#
# Usage: sudo scripts/inject-test-key.sh <raw-image> <public-key-file>

set -eu

IMG=${1:-}
PUBKEY=${2:-}

[ -n "$IMG" ] && [ -n "$PUBKEY" ] || {
  echo "usage: $0 <raw-image> <public-key-file>" >&2
  exit 1
}
[ -f "$IMG" ]    || { echo "[inject-key] no such image: $IMG" >&2; exit 1; }
[ -f "$PUBKEY" ] || { echo "[inject-key] no such key: $PUBKEY" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "[inject-key] must run as root (loop-mounts the image)" >&2; exit 1; }

MNT=$(mktemp -d)
LOOP=""

cleanup() {
  [ -n "$LOOP" ] && {
    mountpoint -q "$MNT" && umount "$MNT"
    losetup -d "$LOOP" 2>/dev/null || true
  }
  rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

# -P scans the partition table and creates <loop>p1, <loop>p2, ...
# The image is GPT: p1 is the ESP, p2 is the ext4 root (mkimage.sh).
LOOP=$(losetup --show -fP "$IMG")
ROOT_PART="${LOOP}p2"

[ -b "$ROOT_PART" ] || {
  echo "[inject-key] root partition $ROOT_PART not found; partitions are:" >&2
  lsblk "$LOOP" >&2 || true
  exit 1
}

mount "$ROOT_PART" "$MNT"

install -d -m 0700 "$MNT/root/.ssh"
cat "$PUBKEY" > "$MNT/root/.ssh/authorized_keys"
chmod 0600 "$MNT/root/.ssh/authorized_keys"

# sshd refuses key auth for an account whose password field is `!` or
# `*` only when the whole account is expired; a locked password is fine.
# Nothing else to change: the shipped sshd_config leaves PermitRootLogin
# at the upstream default of prohibit-password, which permits keys.
echo "[inject-key] installed $(basename "$PUBKEY") -> /root/.ssh/authorized_keys"

sync
