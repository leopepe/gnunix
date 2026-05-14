# ADR-012: Module-first kernel architecture

**Status:** Proposed
**Date:** 2026-05-14

## Context

`images/lfs-core/kernel.config` is a small fragment (~50 lines, all `=y`)
applied on top of `make ARCH=arm64 defconfig`. Everything we override is
currently built into the kernel image: GPU drivers, virtio-net, FAT
filesystem, framebuffer console, etc. The defconfig under us produces
~3000 modules during `make modules`; they're installed to
`$LFS/lib/modules/<ver>/` but very few are actually *needed* on the running
Tart VM today.

Two consequences as we expand to multi-platform (ADR-010):

1. The `=y` set is implicitly tuned for **Tart on aarch64**. The Raspberry
   Pi variant needs different drivers (BCM2835, vc4); a hypothetical NUC
   variant needs i915 / e1000e / iwlwifi. Today every platform would
   either ship every other platform's drivers built-in or fork the kernel
   config — neither is clean.

2. Every additional `=y` driver bloats `vmlinuz` and increases boot RAM,
   even on hosts that never use that hardware.

The fix is structural: shift everything that's not strictly needed to
mount root and reach `/sbin/init` to `=m`, then let `eudev coldplug`
auto-load modules for the hardware that actually shows up.

The supporting bits are already in place:

- `rc.S:30` runs `udevadm trigger --action=add` after starting `udevd`,
  which is exactly what walks `/sys` and `modprobe`s the matching
  `MODALIAS` for every present device.
- `04-finalize.sh:34-36` already does `make modules` + `make modules_install
  INSTALL_MOD_PATH=$LFS`. `/lib/modules/<ver>/` ships with the rootfs.
- `kmod` (the `modprobe` family) is pulled in transitively by `eudev`'s
  build, so the `=m` userland is satisfied.

What's missing is the configuration discipline: a written rule for what
stays `=y`, a separate fragment for `=m` overrides, and a place for
per-platform explicit-load needs.

## Decision

### Boundary

Stays `=y` (built into the kernel image) — anything required between BIOS
hand-off and the first `/sbin/init` run:

| Subsystem | CONFIGs | Reason |
|---|---|---|
| Boot entry | `EFI`, `EFI_STUB` | GRUB hands us off via EFI stub; the stub IS the kernel. |
| Console early | `TTY`, `VT`, `HVC_DRIVER`, `VIRTIO_CONSOLE` | Kernel messages must be visible from second 0; `agetty` on `/dev/hvc0` (inittab line 1) starts before eudev coldplug. |
| PCI bus | `PCI`, `VIRTIO`, `VIRTIO_PCI` | Required to enumerate virtio-blk. |
| Root storage | `VIRTIO_BLK` | Mounts `/`. If modular, would need an initramfs containing `virtio_blk.ko` — extra complexity we deliberately avoid. |
| Root filesystem | `EXT4_FS`, `EXT4_USE_FOR_EXT2` | Mounts `/`. |
| Early /dev | `DEVTMPFS`, `DEVTMPFS_MOUNT`, `TMPFS`, `DEVPTS` | `rc.S` mounts these before eudev. |

Becomes `=m` — auto-loaded by eudev coldplug from `/sys` MODALIAS entries:

| Subsystem | Today's `=y` config | Why modular is fine |
|---|---|---|
| Network | `VIRTIO_NET` | `rc.network` runs after `rc.S`; eudev has loaded the module by then. |
| Memory ballooning | `VIRTIO_BALLOON` | Cosmetic/perf, no boot dependency. |
| Input | `VIRTIO_INPUT` | Needed at compositor start (Phase 4), not at boot. |
| Alt bus | `VIRTIO_MMIO` | Only matters on ARM virt machines that don't expose a PCI bus — we boot via virtio-pci. |
| GPU | `DRM`, `DRM_VIRTIO_GPU`, `FB`, `FRAMEBUFFER_CONSOLE` | Loaded when sway opens `/dev/dri/card0`. |
| Optional FS | `VFAT_FS`, `NLS_CODEPAGE_437`, `NLS_ISO8859_1`, `NLS_UTF8` | `mount -a` from `rc.S` triggers them. |

Everything not explicitly overridden inherits the `defconfig` value (which
is overwhelmingly `=m` for drivers — the kernel community's own choice).

### File layout

```
images/lfs-core/
├── kernel.config           # "built-in" set — boot-critical =y only
├── kernel.modules.config   # "=m" overrides applied after kernel.config
└── modules-load.d/         # per-platform explicit-load .conf snippets
    └── README.md           # platform overlays land here later (ADR-010)
```

`04-finalize.sh` appends both fragments to `.config` in order, then runs
`olddefconfig`:

```sh
cat kernel.config kernel.modules.config >> .config
make ARCH=arm64 olddefconfig
make -j$JOBS ARCH=arm64 Image modules
make ARCH=arm64 INSTALL_MOD_PATH="$LFS" modules_install
```

### Module load mechanism

Three paths, in priority order:

1. **eudev MODALIAS autoloading** (primary). `rc.S` already runs
   `udevadm trigger --action=add` after `udevd --daemon`. This walks
   `/sys/devices/`, reads each device's `MODALIAS`, and runs `modprobe`.
   Covers the vast majority of cases.

2. **`/etc/modules-load.d/*.conf`** (explicit). One filename per concern.
   Used for: modules that have no `MODALIAS` entry, modules needed before
   a corresponding device exists (e.g., a tunneling network module),
   or per-platform variant overlays (RPi-specific GPIO, etc.).

3. **`modprobe` from rc scripts** (per-service). E.g., a future
   `rc.bluetooth` would `modprobe btusb` instead of expecting eudev to
   have loaded it. Used sparingly.

`systemd-modules-load.service` is not available — we run sysvinit. A
small `rc.modules` shell script (TODO) reads `/etc/modules-load.d/*.conf`
and runs `modprobe -ab` on each name. `rc.S` invokes `rc.modules` after
`udevadm trigger` so eudev-autoloaded modules win when both paths apply.

### Cross-platform fit

The `kernel.modules.config` is **aarch64-specific** today; once x86_64
lands (ADR-010), a parallel `kernel.modules.x86_64.config` will live next
to it, picked by `04-finalize.sh` based on `manifest.json:active_arch`.

Per-platform `=y` *additions* (RPi-specific drivers that need to be
built-in for the Pi to boot at all — VC4 firmware loader, BCM2835 MMC
controller for the SD card root) are out of scope for ADR-012; that's
Phase 6 work. The expected pattern is `kernel.config.rpi-native` merged
in addition to the base.

## Consequences

- `vmlinuz-<ver>` shrinks meaningfully — exact numbers depend on the
  driver set the defconfig pulled in; expect a few MB off the boot image.
- Boot is faster (less to decompress, fewer init paths walked) — small
  win on a VM with fast storage; bigger on bare-metal SD-card boots.
- `lsmod` post-boot now shows the actually-loaded set. We get
  observability of what hardware the VM actually has.
- The default `lfs-core` image's `/lib/modules/<ver>/` is the same size
  (or slightly larger, since some `=y` becomes `=m` — but
  `make modules_install` always copies the modular set).
- Need to add a new `rc.modules` script + `images/lfs-core/etc/rc.d/rc.S`
  change to invoke it.
- One new build dependency: nothing new — `kmod` is already in via eudev.

## Out of scope (not chosen)

- **Initramfs.** Tempting because it'd let us make `VIRTIO_BLK` modular
  too, but it adds: an initramfs build step (busybox or microbusybox),
  a place to host the cpio.gz, GRUB updates to load the initrd. The
  ~50 KB we'd save on `vmlinuz` isn't worth the operational complexity
  for a VM that always has virtio-blk. Revisit when we target real
  hardware that varies (NVMe vs SATA vs SCSI).
- **Compressed modules** (`MODULE_COMPRESS_ZSTD`). nixpkgs ships
  uncompressed; if we ever turn it on, both sides need agreement.
  Trivial to flip later.
- **Module signing.** Separate hardening concern; deserves its own ADR
  alongside Secure Boot.
- **DKMS / out-of-tree modules.** Userland's problem; Nix layer handles
  any out-of-tree driver via nixpkgs.linuxPackages.

## How to roll out

1. Add `images/lfs-core/kernel.modules.config` with the `=m` overrides
   listed under "Decision §1".
2. Add `images/lfs-core/modules-load.d/` directory with a placeholder
   README documenting the convention.
3. Write `images/lfs-core/etc/rc.d/rc.modules` that reads
   `/etc/modules-load.d/*.conf` and `modprobe -ab` each name.
4. Edit `images/lfs-core/stages/04-finalize.sh`:
   - Append both `kernel.config` and `kernel.modules.config` before
     `olddefconfig`.
   - Install `rc.modules`.
5. Edit `images/lfs-core/etc/rc.d/rc.S` to invoke `rc.modules` after the
   `udevadm trigger` line.
6. Rebuild — kernel only (~10-20 min on M-series). No full LFS rebuild
   needed because nothing in stages 01–03 cares about the kernel config:

   ```sh
   REUSE_BUILDER=1 tools/build-all.sh lfs-core   # re-runs stage 04
   ```

7. `tests/boot-smoke.sh lfs-core-0.1.0` — must still pass (DHCP +
   sshd up means VIRTIO_NET was auto-loaded by eudev).
8. Re-layer Nix and Wayland on top.

## References

- Linux kernel `Documentation/admin-guide/module-signing.rst` for the
  signing-deferred path.
- `eudev` README — `MODALIAS` auto-load semantics.
- Linux `Documentation/kbuild/modules.rst` — module-install layout.
- Slackware's historical `/etc/rc.d/rc.modules` — pattern we follow.
