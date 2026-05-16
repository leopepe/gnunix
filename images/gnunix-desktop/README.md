# `gnunix-desktop`

`gnunix-minimal` + **Hyprland pre-baked** as the reference Wayland
desktop. The "default GNUnix desktop experience" published as a
ready-to-run `.img.zst` / `.tart.zst` — boot and you land in greetd →
tuigreet → Hyprland.

## Objective

Ship a graphical workstation that respects the project's two-layer
model: substrate (`dbus`, `elogind`, `greetd`, `seatd` where
relevant) provisioned from `nixpkgs` into
`/nix/var/nix/profiles/system`, compositor + portal pre-installed,
no desktop environment forced on the user. Anything beyond Hyprland
(Sway, labwc, COSMIC, …) lives in the installer as an opt-in
profile, not here.

## Summary of features

- **Hyprland** as the reference compositor (ADR-020). Dynamic
  tiling + animations, with `xdg-desktop-portal-hyprland` and
  `hyprpaper` pulled in. Sway is **not** in the pre-baked closure;
  it returns as an installer-time profile via
  `gnunix-installer`.
- **`greetd` + `tuigreet`** owns vt1 (ADR-009). The session wrapper
  at `/usr/local/bin/start-wayland-session.sh` `exec`s `Hyprland`.
- **Wayland-only** — no X11, no XWayland in the base. ADR-009 is
  unambiguous about this.
- **`dbus` and `elogind` from nixpkgs**, installed into the system
  profile per ADR-009; `seatd` where relevant for the `seat` group.
- **`waybar`, `foot`, `wayland-utils`** pre-installed for a working
  out-of-the-box bar + terminal + session-diagnostic toolchain.
- **`/etc/hypr/hyprland.conf`** + per-user starter at
  `~/.config/hypr/hyprland.conf`, both with `WLR_NO_HARDWARE_CURSORS,1`
  set so the cursor is visible on virtio-gpu (Tart's GPU, and most
  VMs').
- **Multi-user Nix daemon** inherited from `gnunix-minimal`.
- **User in `wheel`, `video`, `input`, `render`, `audio`, `seat`
  groups** — what libinput, DRM, audio, and logind need.

## Layout

```
build.sh                    host orchestrator: clones gnunix-minimal-<ver>,
                            scp's etc/ + install-gnunix-desktop.sh into the
                            VM, runs the installer, snapshots the result as
                            gnunix-desktop-<ver>.
install-gnunix-desktop.sh   in-VM provisioner: nix-env -iA of greetd +
                            tuigreet + Hyprland + hyprpaper + portal +
                            waybar + foot; writes the greetd config and
                            the session wrapper; creates the unprivileged
                            user.
etc/                        rootfs /etc skeleton additions
  greetd/config.toml        greetd config (autologin off, points at the
                            session wrapper)
  hypr/hyprland.conf        starter system-level Hyprland config
  rc.d/rc.greetd            greetd supervisor (chmod +x to enable)
```

## Build

```sh
# Requires gnunix-minimal-<ver> on disk (build or fetch):
tools/build-all.sh gnunix-desktop
# → cache/artifacts/gnunix-desktop-aarch64-<ver>.img(.zst)
```

## What it does NOT ship

By design (root `CLAUDE.md` § "Guiding philosophy" + ADR-020):

- **No second compositor in the pre-baked image.** Sway, labwc,
  labwc-nextspace, COSMIC are installer-time picks (see
  `images/installer/`).
- **No DE shell** — no GNOME-Shell, no Plasma, no MATE. GNUnix
  ships a compositor + a bar + a terminal. Anything beyond that is
  the user's choice via Nix or home-manager.
- **No X11 fallback.** Wayland-only, including no XWayland in the
  base.
- **No theming.** Users theme their own (`~/.config/hypr/`).

## Validate

```sh
tests/desktop/wayland-session.sh gnunix-desktop-<ver>
```

Asserts: greetd up, tuigreet on tty1, dbus + elogind running, the
session wrapper boots Hyprland on virtio-gpu, `hyprctl version`
succeeds, `foot` opens. Mandatory gate for any change under
`images/gnunix-desktop/`.

## See also

- [ADR-009](../../docs/adrs/ADR-009-wayland-stack.md) — Wayland substrate
- [ADR-020](../../docs/adrs/ADR-020-compositor-switch-hyprland.md) — Hyprland as reference
- [`images/installer/`](../installer/) — the alternative-compositor picker
- [`docs/runbooks/hyprland-quick-reference.md`](../../docs/runbooks/hyprland-quick-reference.md) — keybinds + first-boot tips
