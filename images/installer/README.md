# `gnunix-installer`

A live installer image that lets the end user pick **what flavor of
GNUnix to install** and **which Wayland compositor to use**, instead of
forcing the choice at download time.

See [ADR-015](../../docs/adrs/ADR-015-installer-and-sessions.md) for
the design rationale.

## Profiles

| id | What lands on target | Compositor style |
|---|---|---|
| `minimal` | `gnunix-minimal` (LFS + Nix daemon, no GUI) | — |
| `desktop-sway` | desktop + Sway + waybar (already in the rootfs) | tiling (i3-style) |
| `desktop-hyprland` | desktop + Hyprland (pulled at install) | dynamic tiling + animations |
| `desktop-labwc` | desktop + labwc (pulled at install) | stacking (Openbox-style) |

GNUnix is Wayland-only — X11/Xorg is out of scope. Authentic
BeOS-themed XFCE and WindowMaker/GNUstep aesthetics would require X11
and aren't offered.

## Layout

```
build.sh                    host orchestrator
install-installer.sh        in-VM provisioner
installer/
  gnunix-installer          whiptail TUI; bash
  profiles/
    minimal.sh
    desktop-sway.sh
    desktop-hyprland.sh
    desktop-labwc.sh
```

## Status

**Scaffolded.** The TUI runs and dispatches to per-profile scripts;
partitioning + rsync + GRUB-install paths are sketched but only the
`minimal` and `desktop-sway` profiles have been validated end-to-end
on a real target. The Hyprland and labwc profiles are coded but
unbuilt-against-target until the first install attempt.

## Build flow

```sh
# After gnunix-desktop-<ver> is built:
tools/build-all.sh gnunix-installer
# → cache/artifacts/gnunix-installer-aarch64-<ver>.img(.zst)
```

The installer image is the leaf of the desktop branch — nothing layers
on top of it; it's what an end user downloads.

## Install flow (end user)

1. Download `gnunix-installer-aarch64-<ver>.img.zst` and decompress.
2. Write to a USB stick:
   ```
   sudo dd if=gnunix-installer-aarch64-0.1.0.img of=/dev/sdX bs=4M status=progress conv=fsync
   ```
3. Boot the target machine from the USB.
4. At the greetd prompt, pick **Install GNUnix** (or **Try live (Sway)**
   to try the system before installing).
5. The whiptail TUI walks through: target disk → profile → user/host →
   confirm → install.
6. Reboot into the installed system.

## Why pull packages at install time?

Bundling all three Wayland compositors into the installer ISO would
inflate it noticeably. Pull-at-install keeps the installer image
close to `gnunix-desktop`'s size and fetches the chosen compositor's
closure from `cache.nixos.org` into the **target's** Nix store. The
`minimal` and `desktop-sway` profiles work offline; `desktop-hyprland`
and `desktop-labwc` require network at install. The TUI warns about
this on the profile-selection screen (TODO once we wire that in).
