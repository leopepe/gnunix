# ADR-015: Live installer + multiple graphical session choices

**Status:** Proposed (amended by [ADR-017](ADR-017-live-iso-architecture.md), [ADR-019](ADR-019-image-lineage-and-installer-pivot.md))
**Date:** 2026-05-14
**Amended:** 2026-05-15 — ADR-017 replaces the raw `.img` artifact with a proper hybrid EFI live ISO (squashfs + overlayfs + custom initramfs). ADR-019 pivots the installer to layer on `gnunix-minimal` instead of `gnunix-desktop` (text-only live env), reshapes the TUI to "edition → compositor → identity", and removes the greetd session menu from the live image.

## Context

Up to now GNUnix has shipped two end-user products as raw disk images:
`gnunix-minimal` (CLI + Nix) and `gnunix-desktop` (Sway + waybar). Users
get the image by `dd`-ing the `.img` to a disk and rebooting — no choice,
no customization at install time.

Two requirements that this ADR addresses:

1. **A single download with both flavors** instead of forcing users to
   pick `gnunix-minimal` vs `gnunix-desktop` *before* trying anything.
2. **Multiple graphical session options** for the desktop path. Sway is
   the only one we ship today; we want to also offer Hyprland and labwc
   so users can pick tiling-with-effects or stacking/Openbox-style
   layouts without rebuilding the image.

Constraints:

- We're sysvinit + Nix. No NixOS module system. No systemd activation.
- The installer should fit the "boring base, declarative top" rule:
  partitioning + rsync + bootloader writes via plain shell; per-session
  setup via Nix nominal installs into the **target's** Nix store.
- Architecturally compatible with ADR-010 (per-platform packagers):
  the installer image IS the existing `nuc-installer`/`generic-uefi`
  hybrid pattern, generalized.

## Decision

### One image carries both flavors: `gnunix-installer`

A new build target produces `gnunix-installer-<arch>-<ver>.iso` (and a
matching `.img` for direct-`dd` consumers). The installer is built **on
top of `gnunix-desktop`** so it inherits the entire userland that any
graphical session might need; the minimal path simply doesn't enable
the optional pieces.

Boot flow:

```
GRUB → kernel → init → rc.M → greetd → tuigreet
                                         ├── "Install GNUnix"   ──┐
                                         ├── "Try live (Sway)"     │
                                         └── "Shell"               │
                                                                   │
                                                                   ▼
                                              /usr/local/sbin/gnunix-installer
                                                  (whiptail TUI; bash)
                                              picks target disk + profile + user
                                                  ↓
                                              writes target rootfs, GRUB,
                                              per-profile post-install,
                                              reboot
```

### Installation profiles

GNUnix is **Wayland-only**. X11 and Xorg are explicitly out of scope
(see § "Why no X11"). The three desktop profiles are curated Wayland
compositors covering tiling, dynamic-with-effects, and stacking styles:

| Profile id              | Compositor / stack on target                       | Style |
|---|---|---|
| `minimal`               | `gnunix-minimal` rootfs (LFS + Nix daemon)         | CLI only |
| `desktop-sway`          | `gnunix-desktop` rootfs as-shipped (sway + waybar) | Wayland tiling (i3-style) |
| `desktop-hyprland`      | desktop + Hyprland + waybar                        | Wayland dynamic tiling + animations |
| `desktop-labwc`         | desktop + labwc + waybar                           | Wayland stacking (Openbox-style) |

### Where the extra packages live

Two strategies considered:

| Approach | Image size | Network at install | Maintenance |
|---|---|---|---|
| **Bundle every compositor** | ~1.5–2 GB above gnunix-desktop (Sway already + Hyprland closure + labwc closure + portals) | none required | one image to test |
| **Pull-at-install** | small (~installer ≈ gnunix-desktop) | required (`cache.nixos.org`) | per-profile install scripts |

**Decision: pull-at-install.** The installer ISO carries only what the
*live* environment needs (Sway, for previewing the install). The chosen
profile's compositor + theme assets are fetched into the **target's**
Nix system profile at install time via `nix-env -p
/mnt/gnunix-target/nix/var/nix/profiles/system -iA …`. Same pattern as
`images/gnunix-desktop/install-gnunix-desktop.sh` uses today, just
chrooted into the target rootfs.

Trade-off: requires network at install time for the Hyprland and labwc
profiles. The `minimal` and `desktop-sway` profiles work offline because
their closures are already in the installer image. We document the
requirement clearly. If a "fully offline installer" need shows up
later, the bundle approach becomes a separate variant
(e.g., `gnunix-installer-offline-<arch>-<ver>.iso`).

### Layout

```
images/installer/                     (new — generalization of the
                                       nuc-installer variant idea)
├── build.sh                          (host orchestrator; clones
│                                      gnunix-desktop-<ver>, scps the
│                                      payload, runs install-installer.sh
│                                      inside, promotes, emits .iso/.img)
├── install-installer.sh              (in-VM: stages the installer TUI
│                                      under /usr/local/sbin/, adds the
│                                      "Install GNUnix" greetd session,
│                                      copies profile assets to
│                                      /usr/local/share/gnunix-installer/)
├── installer/                        (payload shipped into the image)
│   ├── gnunix-installer              (the whiptail TUI; bash)
│   └── profiles/
│       ├── minimal.sh                (no-op post-rsync; just stops)
│       ├── desktop-sway.sh           (enables greetd → sway path; no
│       │                              extra nix-env needed — sway is
│       │                              already in the rootfs)
│       ├── desktop-hyprland.sh       (nix-env -iA nixpkgs.hyprland;
│       │                              drops a sensible ~/.config/hypr/)
│       └── desktop-labwc.sh          (nix-env -iA nixpkgs.labwc + a
│                                      starter ~/.config/labwc/)
└── README.md
```

### Greetd session entries (live boot)

The installer ISO's `/etc/greetd/config.toml` is rewritten so tuigreet
offers three named sessions, not just `start-wayland-session.sh`:

```toml
[terminal]
vt = 1

[default_session]
command = "/nix/var/nix/profiles/system/bin/tuigreet --time --asterisks \
  --sessions /etc/greetd/sessions"
user = "greeter"
```

`/etc/greetd/sessions/` contains:

```
install-gnunix.desktop    Exec=/usr/local/sbin/gnunix-installer
try-live.desktop          Exec=/usr/local/bin/start-wayland-session.sh
shell.desktop             Exec=/bin/bash --login
```

tuigreet shows them as a menu before the password prompt.

### Installer TUI flow

`gnunix-installer` is plain bash + `whiptail` (from `newt`, in
nixpkgs). No GUI dependency, runs on tty.

1. **Welcome screen.** Confirms continue.
2. **Disk selection.** `lsblk` → list of block devices ≥ 8 GB; user picks.
3. **Profile selection.** Radio list: minimal / desktop-sway /
   desktop-hyprland / desktop-labwc.
4. **Identity.** hostname, user, password.
5. **Confirm.** Show the target disk and chosen profile; ask Y/N.
6. **Execute** (with progress):
   1. partprobe + sgdisk — GPT, ESP 512 MiB + ext4 root.
   2. mkfs.vfat + mkfs.ext4.
   3. mount target → /mnt/gnunix-target.
   4. rsync live rootfs → target (excludes /proc /sys /dev /run /mnt
      and the installer payload itself).
   5. Re-bind /proc /sys /dev into target; `chroot /mnt/gnunix-target`.
   6. Run `images/installer/profiles/<profile>.sh` inside the chroot.
      That script handles its own `nix-env -iA` for compositor packages
      and writes any per-session config files (sway/config,
      hyprland.conf, labwc rc.xml, …).
   7. `grub-install` to the ESP; write `/boot/grub/grub.cfg`.
   8. Write `/etc/fstab`, `/etc/hostname`, `/etc/os-release` with
      `VARIANT_ID=<profile>`.
   9. Create the user, set password, add to `wheel`/`video`/`input`/…
      groups per profile.
   10. `sync` and `umount`. Tell user to remove the install medium.
   11. Reboot.

### Why no X11

The original draft of this ADR included `desktop-xfce-beos` (XFCE 4.20
with a BeOS-inspired theme) and `desktop-windowmaker` (the canonical
GNUstep WM). Both require the X11/Xorg stack. The project decision is
to be **Wayland-only**; X11 brings the full Xorg server + DRI legacy +
libxcb and adds a meaningful chunk of attack surface and code we'd be
maintaining for shrinking upstream support.

Consequences for retro/classic aesthetics:

- Authentic **BeOS-style** desktops require X11 (XFCE/xfwm4 with yellow
  tabbed titlebars). No Wayland-native compositor reproduces it today.
- Authentic **NeXTSTEP / GNUstep WindowMaker** is X11. There is no
  Wayland WindowMaker.

What we offer instead:

- `desktop-labwc` is the closest analogue to a "traditional" desktop
  on Wayland — Openbox-style stacking with a root menu. **Theming
  labwc + waybar in a BeOS-inspired direction is a possible follow-up
  variant**, but it would be BeOS-*inspired*, not authentic.
- If a user really needs WindowMaker or true X11 XFCE, they're better
  served by a different distro (Alpine, Void, Gentoo). We don't try to
  be everything.

## Consequences

### New build artifacts

- `cache/artifacts/gnunix-installer-aarch64-<ver>.iso`
- `cache/artifacts/gnunix-installer-aarch64-<ver>.img(.zst)` — same
  contents in raw form for `dd`-to-USB consumers.

The installer image is built on top of `gnunix-desktop-<ver>`. CI gains
a `gnunix-installer` job in `.github/workflows/build.yml` after the
existing `gnunix-desktop` job.

### Network at install time

Required for `desktop-hyprland` and `desktop-labwc` (pull from
`cache.nixos.org`). The `minimal` and `desktop-sway` profiles work
offline because their closures are already in the installer image.
The installer warns about this on the profile-selection screen.

### Per-profile QA

Each profile gets a smoke test in `tests/installer/`:

- `tests/installer/profile-minimal.sh` — boot live, run installer in
  unattended mode (env vars instead of TUI), reboot into target, verify
  `nix --version` works.
- `tests/installer/profile-sway.sh` — same + verify greetd → sway boots
  to a Wayland session.
- `tests/installer/profile-hyprland.sh` — verify Hyprland starts and
  serves a Wayland socket.
- `tests/installer/profile-labwc.sh` — verify labwc starts and serves a
  Wayland socket.

All four run in CI under macOS-arm64 Tart. The Hyprland and labwc tests
require network during the test run (they fetch the compositor closure
at install time).

### Operational

- Documentation: `docs/runbooks/install.md` for end users (how to
  flash + boot + install); `docs/runbooks/build-installer.md` for
  maintainers (how the image is produced).
- Naming: `gnunix-installer` joins the lineage as a leaf — it doesn't
  spawn a downstream image, it's the consumer-facing endpoint of the
  desktop branch.

## Out of scope

- **Fully offline installer**. The pull-at-install design needs
  network; an "offline" variant is a future ADR if demand appears.
- **Encrypted root**. The TUI doesn't currently offer LUKS. Adding it
  is a one-question expansion of the partitioning step + a tweak to
  `/etc/crypttab` + `/etc/fstab` and an unlock prompt in early init.
  Deferred.
- **UEFI Secure Boot signing of the installer kernel**. Tracked in
  `docs/TODO.md` under "Verified boot path".
- **A graphical installer**. The TUI is sufficient for the developer
  audience; a GTK installer would add a heavyweight dependency for
  marginal UX gain on this audience.
- **Multi-disk / RAID / LVM**. Single-disk only for v1.
- **i18n in the TUI**. English only for v1.

## Open questions (resolve when implementing)

1. **Default profile** in the menu — pre-select `desktop-sway` (most
   discoverable) or `minimal` (smallest blast radius)? Currently
   `minimal` is the radio default; revisit after first user feedback.
2. **xdg-desktop-portal backends per profile** — Sway uses
   `xdg-desktop-portal-wlr`, Hyprland has `xdg-desktop-portal-hyprland`,
   labwc uses wlr. The profile scripts install the right backend, but
   we should verify screen-share / file-pickers actually work on each
   before promoting profiles to "supported".
3. **BeOS-inspired labwc variant** — explicitly out of scope for the
   installer ADR, but a future ADR could define a `desktop-labwc-beos`
   profile that ships a curated labwc theme + waybar CSS approximating
   BeOS's yellow titlebars and font. Wayland-native, no X11.
