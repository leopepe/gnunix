# ADR-017: Live-ISO architecture for `gnunix-installer`

**Status:** Proposed
**Date:** 2026-05-15

## Context

[ADR-015](ADR-015-installer-and-sessions.md) specified `gnunix-installer`
as a live image that lets users pick an edition + compositor at install
time. The current scaffolding emits a raw `.img` (a full 9 GB VM disk)
that an end user `dd`s onto a USB. That works mechanically but has
three problems:

1. **Size.** 9 GB raw / ~1.5 GB compressed is large for a "go download
   our installer" experience. Users on metered connections balk; the
   target pendrive has to be 16 GB+.
2. **No CD path.** A raw GPT disk image isn't an ISO 9660 filesystem; it
   can't be burned to optical media or attached as a virtual `-cdrom`
   to qemu. Only `dd`-to-USB or block-level VM import works.
3. **Not a "real" live image.** The current `.img` is a snapshot of a
   rootfs with the installer TUI bolted on. Booting it actually mutates
   the disk — write to the wrong partition during testing, lose the
   installer. A proper live image is read-only by construction.

The installer needs a proper live boot architecture: a kernel + initrd
+ squashfs that boots into a RAM-backed overlay, with the underlying
medium read-only the whole time.

## Decision

**Live-ISO architecture: squashfs + overlayfs + a custom minimal
initramfs, packaged as a hybrid EFI-bootable ISO 9660 via `xorriso`.**

### Boot sequence

```
EFI firmware
  └─> /EFI/BOOT/BOOTAA64.EFI            (GRUB EFI, embedded in efi.img)
       └─> /boot/grub/grub.cfg          (live menu)
            └─> linux  /live/vmlinuz  boot=live live-label=GNUNIX_LIVE …
                initrd /live/initrd.img
                 └─> initramfs `init` (POSIX sh, busybox):
                      1. wait for /dev/disk/by-label/GNUNIX_LIVE
                      2. mount that medium read-only at /run/live/medium
                      3. mount /run/live/medium/live/rootfs.squashfs
                         at /run/live/rootfs (ro, loopback)
                      4. mount tmpfs at /run/live/overlay (rw)
                      5. mount overlayfs lower=rootfs upper=overlay
                         → /run/live/root
                      6. mount --move medium and other vfs into the overlay
                      7. switch_root /run/live/root /sbin/init
            └─> /sbin/init (sysvinit) runs on the overlay
                  rc.S → rc.M → installer auto-launches on tty1
```

The overlay tmpfs is RAM-backed: any writes (installer state, logs,
mount points) live in RAM and disappear at reboot. The ISO itself is
never modified. squashfs gives us roughly 3× compression on the rootfs
versus raw ext4.

### ISO layout

```
/EFI/BOOT/BOOTAA64.EFI        GRUB EFI binary (also referenced by El Torito)
/boot/grub/grub.cfg           live boot menu
/live/vmlinuz                 kernel (identical to gnunix-minimal's)
/live/initrd.img              custom initramfs, ~5 MB cpio.gz
/live/rootfs.squashfs         compressed gnunix-minimal rootfs, ~400 MB
/.disk/info                   one-line provenance string
                              (e.g. "gnunix-installer aarch64 0.2.0")
```

The whole tree wraps in ISO 9660 with two refinements:

- **EFI El Torito** boot entry pointing at an embedded `efi.img`
  (FAT16, contains the GRUB EFI binary). Lets EFI firmware boot the
  ISO when it's burned to optical media or attached as `-cdrom`.
- **GPT partitioning** via `xorriso -append_partition`, so when the
  same ISO is `dd`'d to a USB stick, EFI firmware also discovers a
  GPT ESP and boots through that path.

This is the standard hybrid-EFI ISO pattern used by Debian and Fedora
on aarch64.

### Kernel changes — module-first per ADR-012

Add to `images/gnunix-base/kernel.modules.config`:

```
CONFIG_SQUASHFS=m
CONFIG_SQUASHFS_ZSTD=y    # depends-on, not standalone
CONFIG_OVERLAY_FS=m
CONFIG_ISO9660_FS=m
CONFIG_BLK_DEV_LOOP=m
```

These modules are loaded by the initramfs at live boot. The installed
system never loads them (eudev MODALIAS coldplug doesn't fire on
overlayfs or ISO9660 hardware that isn't present). Cost in the
installed system: ~500 KB of `.ko` files under `/lib/modules/<kver>/`
that sit cold.

This follows [ADR-012](ADR-012-module-first-kernel.md) — features
stay available but invisible until needed. It does **not** amend
ADR-012; it's exactly the use case ADR-012 was written for.

### Initramfs design — minimal, sysvinit-friendly, busybox-based

`images/installer/initramfs/` contains:

- **`init`** — POSIX shell script (~150 lines). No bash-isms; runs
  against busybox ash. Performs the boot sequence above. Exits to a
  rescue shell on any failure.
- **`busybox`** — single static binary from `nixpkgs.busybox.static`,
  ~1.5 MB. Provides `mount`, `switch_root`, `sleep`, `blkid`, `find`,
  `mkdir`, `cat`, `sh` — the entire userspace the initramfs needs.
- **Minimal udev-like rules** — small inline script in `init` that
  walks `/sys/class/block/` to find a partition whose
  `udev`-equivalent label matches `GNUNIX_LIVE`. We do not ship full
  eudev in the initramfs; we only need a label lookup, which busybox
  `blkid` handles.

The initramfs is cpio-archived + gzip-compressed at ISO-build time
inside the `gnunix-installer-build` VM. It is **not** part of any
installed rootfs, **not** part of `gnunix-base`, and **not** part of
`gnunix-minimal`. Once `switch_root` runs, the initramfs is unmapped
and freed.

**On the choice of busybox in the initramfs:** ADR-001's "GNU userland,
unapologetically" stance applies to the *system* — the userland the
user logs into and runs daily. An initramfs is by construction a
disposable boot bootstrap: it lives in RAM for ~2 seconds, never
becomes part of a running system, and no installed process inherits
its binaries. Using a static busybox there is the same kind of trade
ADR-001 already accepts for the LFS toolchain's bootstrap stages
(temporary tools, replaced at the end of the build). It does not
introduce busybox into the GNUnix user-facing surface.

### Build flow

`tools/build-all.sh gnunix-installer` chain (after the lineage pivot
described in ADR-019):

1. Clone `gnunix-minimal-<ver>` → `gnunix-installer-build`.
2. Inside the build VM, stage the installer TUI payload and configure
   a getty on tty1 to auto-launch the TUI (with a "drop to shell"
   escape).
3. **New** — invoke `images/installer/iso/mkiso.sh` inside the build
   VM. It:
   - exports the rootfs to a directory, excluding `/proc /sys /dev
     /run /tmp /mnt` and the installer build scaffolding;
   - `mksquashfs <dir> rootfs.squashfs -comp zstd`;
   - builds the initramfs cpio.gz from `images/installer/initramfs/`
     (the `init` script + static busybox);
   - generates `efi.img` (FAT16, contains
     `/EFI/BOOT/BOOTAA64.EFI` from `grub-mkimage`, plus the live
     `grub.cfg`);
   - copies kernel, initramfs, squashfs, and `.disk/info` into an
     ISO staging directory;
   - calls `xorriso -as mkisofs -iso-level 3 -V GNUNIX_LIVE
     -efi-boot-image -append_partition 2 0xef efi.img
     -isohybrid-gpt-basdat -o gnunix-installer-<arch>-<ver>.iso
     staging/`.
4. `scp` the ISO out of the build VM to `cache/artifacts/`.
5. Discard the build VM.

The build VM gets `xorriso`, `squashfs-tools`, `cpio`, `mtools`,
`dosfstools`, and `grub-mkimage` installed via `nix-env` into its
system profile. None of those tools reach any other image.

### Why these specific choices

| Choice | Alternative considered | Why this one |
|---|---|---|
| squashfs + overlayfs | Full rootfs in a large initrd | initrd-only needs 2–4 GB RAM at boot; overlay caps RAM use at what the user actually dirties |
| zstd squashfs compression | xz | zstd decompresses ~3× faster at boot; size differs by ~5% |
| Hybrid EFI ISO (El Torito + GPT) | EFI-only ISO | Adds USB-`dd` compatibility at near-zero size cost |
| busybox-static for the initramfs | Hand-curated LFS-base statics | One drop-in nixpkgs dep vs. building each binary statically from source. Disposable boot context, not the running system. |
| Custom ~150-line init script | `dracut`, `mkinitcpio` | dracut is systemd-coupled; mkinitcpio is Arch tooling. A handwritten init for our exact boot is shorter than learning either tool's hook system, and matches the project's "boring, direct" disposition |
| EFI-only (no BIOS isolinux) | Hybrid BIOS + EFI | aarch64 has no BIOS; ADR-006 makes the project UEFI-only on x86_64 too |
| No zstd wrapper on the ISO | `gnunix-installer-<ver>.iso.zst` | The squashfs inside is already zstd-compressed; outer zstd saves ~5% for ~30 min CI time per build |

## Consequences

### New build artifacts

- `cache/artifacts/gnunix-installer-<arch>-<ver>.iso` (~400–600 MB).
  ISO is the only artifact form for the installer (no `.img.zst`
  fallback; see [ADR-018](ADR-018-artifact-taxonomy.md)).

### Kernel footprint on installed systems

`gnunix-base`'s installed-on-disk `/lib/modules/<kver>/` grows by
~500 KB across four cold modules (`squashfs.ko`, `overlay.ko`,
`isofs.ko`, `loop.ko`). Boot time on installed systems is unchanged
because the modules never load.

### Build-tool footprint

`gnunix-installer-build` pulls `xorriso`, `squashfs-tools`, `cpio`,
`mtools`, `dosfstools` into its system profile during ISO assembly.
The build VM is discarded after the ISO is produced; these tools
reach no other image, no published artifact, and no installed system.

### `gnunix-base` rebuild required

Adding `=m` entries to `kernel.modules.config` is a real kernel
config change. Per [ADR-018](ADR-018-artifact-taxonomy.md) the
manifest version bumps (e.g. 0.1.0 → 0.2.0) and `gnunix-base` is
rebuilt locally on Apple Silicon (one overnight run per
[ADR-016](ADR-016-ci-split-build-and-validation.md)); the new
`.img.zst` ships to the `gnunix-base` GH Release before downstream
CI consumes it via the release-dependency flow defined in ADR-018.

### Testability

New test:

- **`tests/installer/iso-boot.sh`** — boots the ISO in qemu with
  `-cdrom <iso>`, asserts:
  1. kernel reaches userspace,
  2. initramfs reports finding the medium by label,
  3. overlay mount succeeds (one-line marker in `/run/live/state`),
  4. sysvinit starts on the overlay (`/proc/1/comm == "init"`),
  5. installer TUI auto-launches on tty1.

Existing tests:

- **`tests/installer/profile-*.sh`** continue to drive the installer
  unattended against a target disk. They switch from booting a
  raw-`.img` VM to booting the live ISO via `qemu -cdrom` (or
  `tart run --disk=iso:ro` on the macOS dev path).

### CI impact

Per [ADR-018](ADR-018-artifact-taxonomy.md):

- The `gnunix-installer` job in `build.yml` swaps its `*.img.zst`
  artifact upload for `*.iso`.
- The `installer-test` matrix uses `qemu -cdrom` (Linux runner) or
  `tart run --disk=iso:ro` (macOS dev) to boot the live env.
- No structural pipeline change; one artifact-path edit and one
  boot-flag edit.

## Out of scope

- **BIOS legacy boot.** ADR-006 mandates UEFI; the ISO is EFI-only.
- **Persistent overlay on the USB stick** (Ventoy-style writable
  layer that survives reboot). Possible future ADR if demand appears.
- **Net-boot / PXE.** Live env is ISO/USB only. PXE would need a
  different bootstrap. Out of scope for v1.
- **Signed kernel / Secure Boot.** Tracked in `docs/TODO.md` under
  "Verified boot path." The live ISO uses an unsigned GRUB EFI
  binary today.
- **Multi-arch ISO** (one ISO bootable on both aarch64 and x86_64
  via two El Torito entries). Defer until x86_64 ships at all
  (ADR-010 phases 5/6).

## Open questions

1. **Squashfs compression level.** Default zstd level is fine for
   v1. `-comp zstd -Xcompression-level 19` would shave another
   ~10% but is ~5× slower to compress at build time. Revisit if
   ISO size becomes a complaint.
2. **`copytoram=1` at the GRUB level?** Some live distros default
   to copying the entire ISO into RAM at boot for snappier feel.
   We don't, because USB 3 is fast enough and copytoram doubles
   RAM use. Reconsider if users on slow media complain.
3. **`xdg-desktop-portal-hyprland` in the live env?** The live
   environment is text-only (see ADR-019); no compositor runs in
   the live image. Portals are pulled at install time as part of
   the per-profile post-install hook. No portal lives on the ISO.
