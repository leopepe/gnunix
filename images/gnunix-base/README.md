# `gnunix-base`

The static LFS layer — a hand-curated Linux From Scratch aarch64 root
filesystem with `sysvinit` + BSD-style `/etc/rc.d/`, GNU coreutils,
glibc, GCC, and GRUB. Built from source inside `gnunix-builder` and
published as `gnunix-base-<arch>-<ver>.{img.zst,tart.zst}`.

This is the **static base** half of the project sandwich (see root
`CLAUDE.md` § "Guiding philosophy"). It changes rarely. Anything
that evolves week-to-week belongs in the Nix layer
(`gnunix-minimal` and above), not here.

## Objective

Boot a minimal, hardened, init-system-as-first-class-citizen system
that *just works* — kernel + userland + sshd + DHCP, nothing else —
and gives every downstream image a predictable, reproducible
foundation.

## Summary of features

- **`sysvinit` as PID 1**, BSD-style `/etc/rc.d/rc.S` + per-service
  `rc.<svc>` scripts toggled by `chmod +x`. No systemd anywhere
  (ADR-001).
- **GNU userland end-to-end** — `coreutils`, `binutils`, `bash`,
  glibc compiled from source per the LFS-ARM book (ADR-007). No
  `busybox`, no `musl`.
- **Module-first kernel** (ADR-012). Boot-critical drivers are `=y`
  in `kernel.config`; everything else is `=m` in
  `kernel.modules.config` and auto-loaded by `eudev` MODALIAS
  coldplug. `/etc/modules-load.d/*.conf` + `rc.modules` for explicit
  overlays.
- **Compile-time hardening** (ADR-011). `_FORTIFY_SOURCE=3`,
  `-fstack-protector-strong`, `-fstack-clash-protection`, PIE, full
  RELRO + BIND_NOW, `-mbranch-protection=standard`. Per-stage and
  per-package exclusions live in `lib/hardening.sh`.
- **GRUB EFI bootloader** (ADR-006). Generic GPT + UEFI + ext4 disk
  image bootable in Tart, qemu, libvirt, UTM, Proxmox, and on Apple
  Silicon hardware.
- **`eudev` for /dev management**, `dhcpcd` for the network,
  `openssh` for remote access, `vim`/`less`/`tar`/`gzip` for
  comfort. That's it.

## Layout

```
build.sh                  host orchestrator (clones gnunix-builder:base
                          → gnunix-builder-build, drives the stages)
stages/                   per-stage build scripts run inside gnunix-builder
  01-cross-toolchain.sh   ~3 h: cross-compile binutils-pass1, gcc-pass1, glibc, …
  02-temp-tools.sh        ~1 h: native temporary tools in /tools
  03-chroot.sh            host-side chroot orchestration
  03b-chroot-inner.sh     in-chroot: final native rebuild + install of base packages
  04-kernel.sh            kernel build (config = kernel.config ++ kernel.modules.config)
  05-finalize.sh          /etc skeleton, rc.d perms, /root/.ssh, default users
kernel.config             boot-critical CONFIG_* (=y)
kernel.modules.config     loadable modules (=m)
modules-load.d/           rc.modules input — explicit module load overlay
etc/                      rootfs /etc skeleton (rc.d, inittab, fstab, ssh, …)
packaging/
  mkimage.sh              losetup + partition + mkfs.* + install rootfs + grub-install
  tart-import.sh          ingest the raw .img into ~/.tart/vms/
lib/
  hardening.sh            per-package hardening export helper (ADR-011)
grub.cfg                  template grub.cfg dropped into /boot/grub/
```

## Build

```sh
# First-time, full rebuild (~6–10 h on Apple Silicon — see ADR-021).
tools/build-all.sh gnunix-base

# Resume a partial build (keeps gnunix-builder-build, picks up where the
# in-VM stage markers left off):
REUSE_BUILDER=1 tools/build-all.sh gnunix-base
```

Per ADR-021, **CI does not rebuild this image** — the build runs on
the maintainer's unmanaged Mac and ships as a GH Release artifact
under the `base-images-<ver>` tag. Downstream layers fetch it via
`tools/fetch-image.sh`.

## Validate

```sh
tests/base/boot-smoke.sh gnunix-base-<ver>
```

Asserts: boot, DHCP, TTY login, `dbus` running, `nix-daemon`
responsive. The PR template's "How validated" checklist gates on
this for any change touching `gnunix-base/`.

## See also

- [ADR-001](../../docs/adrs/ADR-001-init-system.md) — sysvinit + `/etc/rc.d/`
- [ADR-006](../../docs/adrs/ADR-006-bootloader.md) — GRUB EFI
- [ADR-007](../../docs/adrs/ADR-007-arm64-lfs.md) — LFS-ARM (aarch64)
- [ADR-011](../../docs/adrs/ADR-011-compile-time-hardening.md) — compile-time hardening
- [ADR-012](../../docs/adrs/ADR-012-module-first-kernel.md) — module-first kernel
- [`docs/runbooks/build.md`](../../docs/runbooks/build.md) — the full build runbook
