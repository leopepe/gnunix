#!/bin/sh
# Provision the gnunix-builder VM with everything needed to build LFS.
# Run inside the freshly-installed Debian arm64 VM, as root.
#
# This script is idempotent — re-running is safe.

set -eu

LFS_USER=${LFS_USER:-lfs}
LFS_MOUNT=${LFS_MOUNT:-/mnt/lfs}

echo "[provision] apt update + base build deps"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  bash bison gawk gcc g++ make patch perl python3 texinfo \
  binutils bzip2 coreutils diffutils file findutils gettext \
  grep gzip m4 sed tar xz-utils \
  libc6-dev libssl-dev libelf-dev libncurses-dev \
  flex bc cpio kmod rsync \
  wget curl ca-certificates git \
  parted dosfstools e2fsprogs gdisk \
  grub-efi-arm64-bin grub-common \
  qemu-utils \
  sudo openssh-server

echo "[provision] create lfs user and mount point"
if ! id "$LFS_USER" >/dev/null 2>&1; then
  useradd -s /bin/bash -m -k /dev/null "$LFS_USER"
  passwd -d "$LFS_USER"
fi
echo "$LFS_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/lfs
chmod 0440 /etc/sudoers.d/lfs

mkdir -p "$LFS_MOUNT"
chown "$LFS_USER":"$LFS_USER" "$LFS_MOUNT"

echo "[provision] enable sshd"
systemctl enable --now ssh || true

echo "[provision] verify host symlinks expected by LFS"
for sym in /bin/sh /usr/bin/awk /usr/bin/yacc; do
  if [ ! -e "$sym" ]; then
    echo "warning: missing $sym (LFS host requirements check will catch this)" >&2
  fi
done

echo "[provision] done. VM is ready to build LFS as user '$LFS_USER' with \$LFS=$LFS_MOUNT"
