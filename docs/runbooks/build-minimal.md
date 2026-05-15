# Runbook: Building gnunix-minimal from gnunix-base

Phase 3 layers the multi-user Nix daemon (ADR-003) on top of `gnunix-base-<ver>` and produces `gnunix-minimal-<ver>`. The base image isn't rebuilt — Phase 3 reuses Phase 2's output.

Wall time: **~5–10 min** on M-series. No compilation; this is a binary install of Nix + a Tart clone.

## Prerequisites

- `gnunix-base-<ver>` already exists in `tart list`. If not, run Phase 2 first (`tools/build-all.sh gnunix-base`).
- Host has `~/.ssh/id_ed25519.pub` (or another default identity). Phase 2 installed it as `root`'s `authorized_keys` inside `gnunix-base`, so `build-nix.sh` can SSH in.

## One command

```sh
tools/build-all.sh gnunix-minimal
```

This calls `images/gnunix-minimal/build.sh`, which:

1. Verifies `gnunix-base-<ver>` exists.
2. Verifies (or fetches) `cache/sources/nix-2.24.10-aarch64-linux.tar.xz` and checks its sha256 against `tools/manifest.json:nix.binary_sha256`.
3. `tart clone gnunix-base-<ver> → gnunix-minimal-build` (disposable working copy).
4. Boots `gnunix-minimal-build`, waits for `root@<ip>` to answer SSH (~30s).
5. scps the tarball + `images/gnunix-minimal/install-nix.sh` into the VM.
6. Runs `install-nix.sh` over SSH — manual multi-user install (see below).
7. `sync; tart stop`.
8. `tart clone gnunix-minimal-build → gnunix-minimal-<ver>` (the deliverable).
9. Copies `~/.tart/vms/gnunix-minimal-<ver>/disk.img` → `cache/artifacts/gnunix-minimal-disk-<ver>.img` and zstd-compresses it. The raw disk is a portable bootable artifact; Tart is one consumer (see "Consumers" below).

## Smoke test

```sh
tests/minimal-smoke.sh gnunix-minimal-0.1.0
```

Boots the image, ssh's in as root, validates:

- `nix --version` reports 2.24.10
- `nix-store --version` reports 2.24.10
- `nix-daemon` is running (multi-user mode via `/etc/rc.d/rc.nix-daemon`)
- `nix-store -q --hash /nix/var/nix/profiles/default` returns a hash
- `nixbld1`, `nixbld32`, and the `nixbld` group exist in /etc

WARN-only (won't fail): dbus (still deferred — Phase 3.5 or Phase 4 work).

## What install-nix.sh does (multi-user install without systemd)

The official Nix `install-multi-user` script requires systemd or launchd. We have sysvinit (ADR-001), so we replicate its core actions manually:

1. **Create `nixbld` group + 32 users** with uid/gid 30000+. Standard Nix sandboxing pool.
2. **Create `/nix` layout** — `/nix/store` (mode 1775, group nixbld), `/nix/var/nix/{db,profiles,gcroots,...}` with correct permissions per the upstream installer.
3. **Copy `store/` from the tarball into `/nix/store/`** — preserves perms/times/symlinks.
4. **`nix-store --load-db < .reginfo`** — populates the SQLite store database with the tarball's pre-validated paths.
5. **Bootstrap profile** — `nix-env -i $NIX_INSTALLED_NIX --profile /nix/var/nix/profiles/default` plus the same for the CA cert bundle. Creates `/nix/var/nix/profiles/default/bin/nix` symlinked to the actual store path.
6. **Write `/etc/nix/nix.conf`** — `build-users-group = nixbld`, `sandbox = true`, `extra-experimental-features = nix-command flakes`, `extra-trusted-users = root`.
7. **Write `/etc/profile.d/nix-daemon.sh`** — system-wide shell integration. `/etc/profile` (shipped by gnunix-base) already sources it conditionally.
8. **Symlink `/etc/ssl/certs/ca-certificates.crt` → Nix's bundle** so non-Nix tools also get a working CA store.
9. **Overwrite `/etc/rc.d/rc.nix-daemon`** with a corrected supervisor (older versions don't detach the daemon's stdio, which makes SSH sessions hang). `chmod +x` so rc.M starts it on the next boot.

The daemon is **not started during install** — rc.M brings it up on the next boot. Starting it mid-install over SSH triggered orphan-fd hangs in earlier iterations.

## Inspecting and using the running VM

```sh
tart run --no-graphics gnunix-minimal-0.1.0 &
. scripts/tart-helpers.sh
IP=$(tart_ip gnunix-minimal-0.1.0)
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$IP
```

Inside the VM:

```sh
nix --version                                       # 2.24.10
pidof nix-daemon                                    # running
nix-env -qaP firefox 2>/dev/null | head             # query nixpkgs (needs network + channel)
nix-shell -p hello --run hello                      # one-shot environment
```

You'll likely want to add a channel on first interactive use (we don't ship one):

```sh
nix-channel --add https://nixos.org/channels/nixos-25.11 nixpkgs
nix-channel --update
```

Per ADR-004, all userland-managed-by-Nix flows through `home-manager`. Adding home-manager and a basic user is the next runbook (not yet written).

## Consumers of the produced image

The disk image at `cache/artifacts/gnunix-minimal-disk-0.1.0.img` is a generic GPT/UEFI/ext4 disk. Anything that boots a raw disk image works:

- **Tart on macOS (arm64)** — `tart clone` is the easiest; `tart-import.sh` does this automatically.
- **QEMU/KVM on Linux (arm64 host or x86 host with TCG)** — `qemu-system-aarch64 -M virt -cpu host -bios <edk2-aarch64-code.fd> -drive file=gnunix-minimal-disk-0.1.0.img,format=raw -nographic`.
- **libvirt / virt-manager** — define a domain pointing at the raw image, EFI firmware, virtio-blk, virtio-net.
- **UTM on macOS** (alternative to Tart, also Virtualization.framework backed) — import the raw image.
- **Proxmox / cloud uploaders** — usually want qcow2; convert with `qemu-img convert -O qcow2 gnunix-minimal-disk-0.1.0.img gnunix-minimal.qcow2`.
- **Physical hardware** with an arm64 board that supports UEFI — `dd if=gnunix-minimal-disk-0.1.0.img of=/dev/sdX` (be careful with the target device).

**About Tart on Linux**: as of this writing, Tart itself is macOS-only — it uses Apple's Virtualization.framework, which doesn't exist on Linux. On a Linux build host, use QEMU/libvirt for the same role (boot the disk image, smoke-test). The `mkimage.sh` part of the pipeline already runs inside the `gnunix-builder` Linux VM, so the artifact-production side is host-OS-agnostic; only the smoke-test step assumes Tart-on-macOS.

## Iterating

If `install-nix.sh` needs a change and `gnunix-minimal-build` is still around:

```sh
# Re-run only the install step on the already-cloned working VM.
tools/build-all.sh gnunix-minimal
```

`build.sh` re-clones `gnunix-base-<ver> → gnunix-minimal-build` every time, so there's no leftover state to worry about between attempts (unlike Phase 2's `REUSE_BUILDER=1`).

If you want to keep the in-progress VM between attempts (e.g. you scp'd manual changes), don't re-run the orchestrator — ssh in and iterate manually, then `tart stop` + `tart clone gnunix-minimal-build gnunix-minimal-0.1.0`.
