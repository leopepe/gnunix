# lfs-builder

Phase 1 image: a Linux arm64 VM with all build dependencies installed, used as the host environment for the LFS build.

## Why Ubuntu (cirruslabs prebuilt) instead of Debian netinst

The original plan was to install Debian arm64 from the netinst ISO, but the installer is interactive and cannot run unattended without a preseed. To keep the bootstrap reproducible and scriptable, we pull the prebuilt `ghcr.io/cirruslabs/ubuntu:latest` Tart-native image. Ubuntu is Debian-family, so `provision.sh` (apt-based) works unchanged. The choice of *builder host* OS does not affect the LFS *target* — the target is still hand-built LFS aarch64 per ADR-007.

The prebuilt image's default user is `admin` with password `admin` (see `tools/manifest.json:host_distro_for_builder`).

## Build procedure

From the macOS host:

```sh
cd ~/Workspace/lfs-nix-distro

# 1. Pull the prebuilt Ubuntu base (~3GB; cacheable, one-time)
tart pull ghcr.io/cirruslabs/ubuntu:latest

# 2. Clone into our working name + grow disk for LFS sources/builds
tart clone ghcr.io/cirruslabs/ubuntu:latest lfs-builder
tart set lfs-builder --disk-size 60

# 3. Boot in the background and wait for SSH
tart run --no-graphics lfs-builder &
scripts/tart-helpers.sh   # source for tart_wait_ssh
. scripts/tart-helpers.sh
tart_wait_ssh lfs-builder admin

# 4. Push and run provision.sh inside the VM
BUILDER_IP=$(tart ip lfs-builder)
scp -o StrictHostKeyChecking=no images/lfs-builder/provision.sh admin@$BUILDER_IP:/tmp/
ssh -o StrictHostKeyChecking=no admin@$BUILDER_IP "sudo bash /tmp/provision.sh"

# 5. Snapshot
tart stop lfs-builder
tart clone lfs-builder lfs-builder:base
```

The cloned image `lfs-builder:base` is the input to Phase 2.
