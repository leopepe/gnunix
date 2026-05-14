# `rpi-native` variant

Raspberry Pi 4 / 5 image with **native firmware boot** — no UEFI shim, no
GRUB. The VideoCore GPU does first-stage bootloading; the Arm cores come up
second.

## Why native and not UEFI?

ADR-010 picks native as the default for Pi:

- Pi 5 has no official UEFI firmware build (only the community
  `worproject/rpi5-uefi`, fragile on D0 silicon).
- The pftf UEFI build for Pi 4 caps RAM at 3 GiB.
- Native gives you the upstream kernel's GPU / VPU / camera drivers; UEFI
  loses most of them.

UEFI users on Pi can instead consume the `generic-uefi` variant once they
install RPI_EFI.fd onto their SD card themselves.

## Image shape

```
MBR (msdos) — RPi firmware reads MBR, not GPT
├── part1  FAT32  256 MiB  /boot         (firmware + kernel + DTB + config.txt)
└── part2  ext4   rest     /             (LFS rootfs)
```

## /boot contents (Pi 4)

- `bootcode.bin`, `start4.elf`, `fixup4.dat`     — VideoCore firmware
- `kernel8.img`                                   — aarch64 kernel
- `bcm2711-rpi-4-b.dtb`                           — device-tree blob
- `overlays/`                                     — overlay DTBs
- `config.txt`                                    — boot config
- `cmdline.txt`                                   — kernel command line

## /boot contents (Pi 5)

- `kernel_2712.img`                               — Pi 5 kernel (Pi 4 fallback: `kernel8.img`)
- `bcm2712-rpi-5-b.dtb`                           — device-tree blob
- `overlays/bcm2712d0.dtbo`                       — D0-silicon overlay
- `config.txt`, `cmdline.txt`                     — as above
- *(Pi 5 bootloader is in EEPROM — no `bootcode.bin`/`start.elf` needed)*

## Status

**Scaffolded but not yet building** — the `package.sh` rejects the build with
a clear error message until two prerequisites land (tracked in
`docs/TODO.md`):

1. Kernel config additions in `images/lfs-core/kernel.config`: `CONFIG_ARCH_BCM2835`,
   `CONFIG_BCM2835_MMC`, `CONFIG_DRM_VC4`, `CONFIG_BCMGENET`,
   `CONFIG_USB_XHCI_PCI`, `CONFIG_PINCTRL_BCM2835`, `CONFIG_BROADCOM_PHY`.
2. RPi firmware pinned in `manifest.json:platforms["rpi-native"].firmware`
   (`{version, url, sha256}`) and downloaded by `tools/fetch-sources.sh`.

## Usage (once unblocked)

```sh
# Build base aarch64 lfs-nix as today
tools/build-all.sh lfs-nix

# Package as Pi-bootable image
tools/package-platform.sh lfs-nix aarch64 rpi-native
# → cache/artifacts/lfs-nix-rpi-native-aarch64-0.1.0.img.zst

# Flash to SD card / USB
zstd -d lfs-nix-rpi-native-aarch64-0.1.0.img.zst -o /tmp/pi.img
sudo dd if=/tmp/pi.img of=/dev/sdX bs=4M status=progress conv=fsync
```

First boot resizes the root partition to fill the medium.
