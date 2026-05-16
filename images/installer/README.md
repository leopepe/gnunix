# `gnunix-installer`

A live ISO that lets the end user pick **what flavor of GNUnix to
install** (minimal or desktop) and, for desktop, **which Wayland
compositor to use** — without forcing the choice at download time.

See [ADR-015](../../docs/adrs/ADR-015-installer-and-sessions.md) for
the original design, [ADR-017](../../docs/adrs/ADR-017-live-iso-architecture.md)
for the live-ISO architecture, [ADR-019](../../docs/adrs/ADR-019-image-lineage-and-installer-pivot.md)
for the layering pivot, [ADR-020](../../docs/adrs/ADR-020-compositor-switch-hyprland.md)
for the default compositor, and [ADR-022](../../docs/adrs/ADR-022-cosmic-installer-profile.md)
for the COSMIC profile.

## TUI flow

```
1. Welcome
2. Disk
3. Edition       (*) minimal
                 ( ) desktop
4. Compositor    (only if Edition=desktop)
                 (*) hyprland          DEFAULT
                 ( ) sway
                 ( ) labwc
                 ( ) labwc-nextspace
                 ( ) cosmic            (ADR-022)
5. Identity      hostname, user, password
6. Confirm
7. Execute       partition → rsync → chroot →
                 (if desktop) nix-env -iA <compositor> + portal + waybar →
                 grub + fstab → reboot
```

## Profiles

| id                        | Edition | Compositor       | Style |
|---|---|---|---|
| `minimal`                 | minimal | —                | CLI only |
| `desktop-hyprland`        | desktop | Hyprland         | Dynamic tiling + animations (DEFAULT) |
| `desktop-sway`            | desktop | Sway             | Tiling, i3-style |
| `desktop-labwc`           | desktop | labwc            | Stacking, Openbox-style |
| `desktop-labwc-nextspace` | desktop | labwc            | Stacking + NeXTSTEP-inspired theme |
| `desktop-cosmic`          | desktop | cosmic-comp      | System76 COSMIC desktop (ADR-022) |

GNUnix is Wayland-only — X11/Xorg is out of scope (ADR-009/015).

## Live environment

The live env is **text-only** — no compositor, no greetd. After ADR-019:

- `getty` on **tty1** auto-launches the TUI installer.
- `getty` on **tty2** sits at a normal root login prompt for advanced
  users who want to poke around before installing. Switch with
  `Ctrl+Alt+F2`.

## Layout

```
build.sh                  host orchestrator (clones gnunix-minimal, calls
                          install-installer.sh and mkiso.sh inside, scps
                          the ISO back out)
install-installer.sh      in-VM provisioner: stages TUI + getty wrapper,
                          installs ISO build tools into /nix/var/nix/profiles/installer-build
initramfs/
  init                    POSIX sh; mounts medium, squashfs, overlayfs,
                          switch_root into the live system
  build-initramfs.sh      assembles cpio.gz inside the build VM
iso/
  mkiso.sh                squashfs the rootfs + xorriso hybrid EFI ISO
installer/
  gnunix-installer        the whiptail TUI (bash)
  profiles/
    minimal.sh
    desktop-hyprland.sh         (default)
    desktop-sway.sh
    desktop-labwc.sh
    desktop-labwc-nextspace.sh
    desktop-cosmic.sh           (ADR-022)
```

## Build

```sh
# After gnunix-minimal-<ver> is built:
tools/build-all.sh gnunix-installer
# → cache/artifacts/gnunix-installer-aarch64-<ver>.iso (~400–600 MB)
```

## Install (end user)

1. Download `gnunix-installer-<arch>-<ver>.iso`.
2. Write to USB:
   ```
   sudo dd if=gnunix-installer-aarch64-0.2.0.iso of=/dev/sdX bs=4M status=progress conv=fsync
   ```
3. Boot the target machine from the USB. (Try in qemu first:
   `qemu-system-aarch64 ... -cdrom gnunix-installer-aarch64-0.2.0.iso`)
4. The TUI auto-launches on tty1. Walk through: disk → edition →
   compositor (if desktop) → identity → confirm.
5. Reboot into the installed system.

## Network at install time

- `minimal` profile: **works offline** (pure rsync of the live rootfs).
- `desktop-*` profiles: **require network** to `cache.nixos.org`
  (the compositor's closure is pulled at install time, not bundled
  in the ISO). The TUI warns about this on the compositor-selection
  screen.

This is by design (ADR-019 § "Install-time network requirement") —
the alternative was a much larger ISO carrying every compositor.

## Status

- **Build pipeline:** scaffolded for the new live-ISO architecture.
  First end-to-end build still pending; once successful, the ISO is
  shippable.
- **`minimal` profile:** should work offline end-to-end on first
  test.
- **`desktop-*` profiles:** code is in place but the desktop stack
  (greetd, dbus, elogind, portals) provisioning beyond just the
  compositor binary is a known gap from PR-4's reduced scope —
  follow-up PR will pull the full desktop stack into the chroot's
  system profile. Until then, expect that desktop installs complete
  rsync + grub but may not bring up a graphical session on first
  boot.
