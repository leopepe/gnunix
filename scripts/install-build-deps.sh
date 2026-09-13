#!/bin/sh
# Install the host packages the LFS build needs, on Debian/Ubuntu.
#
# Single source of truth for the dependency list, shared by the CI stage
# jobs in .github/workflows/build.yml and mirroring what
# images/gnunix-builder/provision.sh installs in the builder VM. Keeping
# one list means the hosted runner and the maintainer's builder VM cannot
# drift apart — a drift that is invisible until a stage reaches for a tool
# only one of them has.
#
# Deliberately omits the VM-only packages provision.sh also installs
# (sudo, openssh-server, git, qemu-utils): a GitHub runner already has
# them or has no use for them.
#
# Usage: sudo scripts/install-build-deps.sh

set -eu

[ "$(id -u)" = 0 ] || {
  echo "[build-deps] must run as root" >&2
  exit 1
}

export DEBIAN_FRONTEND=noninteractive

# Grouped by what needs them, so a future reader can tell why each is here.
apt-get update -qq
apt-get install -y --no-install-recommends \
  bash bison gawk gcc g++ make patch perl python3 texinfo \
  binutils bzip2 coreutils diffutils file findutils gettext \
  grep gzip m4 sed tar xz-utils zstd \
  libc6-dev libssl-dev libelf-dev libncurses-dev libisl-dev \
  flex bc cpio kmod rsync \
  wget curl ca-certificates \
  parted dosfstools e2fsprogs gdisk \
  grub-efi-arm64-bin grub-common \
  gperf pkgconf

echo "[build-deps] done"
