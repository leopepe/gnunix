# ADR-020: Switch reference compositor from Sway to Hyprland

**Status:** Proposed
**Date:** 2026-05-15
**Amends:** [ADR-009](ADR-009-wayland-stack.md)

## Context

[ADR-009](ADR-009-wayland-stack.md) picked **Sway** as the reference
compositor for `gnunix-desktop`, with the explicit anticipation that
"River, Hyprland, niri all considered — Sway has the lowest support
cost for 'first compositor that has to work everywhere'. Variants
(ADR forthcoming) can offer alternatives without changing the base."
That follow-up is this ADR, with one twist: instead of adding
Hyprland as a *variant alongside* Sway, we make it the **default**
and demote Sway to one of three optional install profiles.

Reasons for the swap, in order of weight:

1. **Maintainer preference and primary daily-driver.** The single
   maintainer (per [ADR-005](ADR-005-audience.md), "this Mac first")
   uses Hyprland day-to-day. The default compositor should be the
   one the maintainer actually exercises against the rest of the
   stack.
2. **Hyprland has matured.** Between ADR-009 (2026-05-13) and today
   it gained stable explicit-sync support, working
   `xdg-desktop-portal-hyprland`, and reasonable virtio-gpu
   behaviour. ADR-009's "lowest support cost" argument was
   correct at the time; the cost has dropped since.
3. **Fit with the developer-workstation audience.** Dynamic tiling
   with animations and overview gestures matches what the audience
   actually wants from a Wayland desktop in 2026. Sway's
   i3-clone simplicity is a feature for a subset, not the median user.

[ADR-019](ADR-019-image-lineage-and-installer-pivot.md) reshapes the
installer to a "Edition → Compositor → Identity" TUI flow with three
compositor options. This ADR settles which of those three is the
default and which is pre-baked into `gnunix-desktop`.

## Decision

### `gnunix-desktop` ships Hyprland pre-baked

`images/gnunix-desktop/build.sh` (the in-VM installer) is updated
to install, from nixpkgs into `/nix/var/nix/profiles/system`:

| Replaces | With |
|---|---|
| `nixpkgs.sway` | `nixpkgs.hyprland` |
| `nixpkgs.swaybg` | `nixpkgs.hyprpaper` |
| `nixpkgs.xdg-desktop-portal-wlr` | `nixpkgs.xdg-desktop-portal-hyprland` |

Unchanged: `nixpkgs.greetd`, `nixpkgs.greetd.tuigreet`,
`nixpkgs.waybar`, `nixpkgs.foot`, `nixpkgs.wayland-utils`,
`nixpkgs.dbus`, `nixpkgs.elogind`.

### Session wrapper

`/usr/local/bin/start-wayland-session.sh` execs `Hyprland`
(note the capital H — Hyprland's binary name) instead of `sway`.

The greetd `config.toml` indirection still points at the wrapper,
so the greetd config itself does not change.

### Starter system config

`/etc/hypr/hyprland.conf` (new, ships in `gnunix-desktop`'s rootfs)
is a minimal-but-usable starter:

- `monitor = ,preferred,auto,1`
- `exec-once = waybar`
- `input { kb_layout = us }`
- Keybinds: `SUPER+RETURN` → foot, `SUPER+Q` → kill active,
  `SUPER+1..9` → workspace, `SUPER+SHIFT+1..9` → move to workspace.
- `general { gaps_in = 4; gaps_out = 8; border_size = 1 }`
- `decoration { rounding = 4; blur { enabled = false } }` — blur off
  on first boot, on by default if the user's GPU survives the
  Wayland smoke test.
- `animations { enabled = true }` with the upstream defaults.
- `env = WLR_NO_HARDWARE_CURSORS,1` — required on Tart's
  virtio-gpu (and most VMs) to avoid an invisible cursor.

The installer per-profile script (`desktop-hyprland.sh`) seeds the
same content into `~/.config/hypr/hyprland.conf` for the created
user, which makes the per-user override the natural extension point.

### Sway demoted to optional install profile

Sway is removed from `gnunix-desktop`'s pre-baked closure. It
remains fully supported as one of three compositor choices in the
installer TUI ([ADR-019](ADR-019-image-lineage-and-installer-pivot.md)):

```
Compositor:
  (*) hyprland   — dynamic tiling + animations (DEFAULT)
  ( ) sway       — tiling, i3-style
  ( ) labwc      — stacking, Openbox-style
```

`images/installer/installer/profiles/desktop-sway.sh` is rewritten
to mirror `desktop-hyprland.sh` and `desktop-labwc.sh`: it pulls
`nixpkgs.sway` + `nixpkgs.swaybg` + `nixpkgs.xdg-desktop-portal-wlr`
into the **target's** system profile via `nix-env -iA` at install
time, seeds `~/.config/sway/config` for the user, points the
session wrapper at `sway`, and enables greetd.

The three profile scripts converge structurally; a
`desktop-common.sh` helper hoists the shared steps (create user,
add to wheel/video/input/render/audio/seat, enable greetd,
install waybar + foot + portal). Each profile script reduces to
its compositor-specific package list + config-file seed.

### Reference-session tests

`tests/wayland-session.sh` (validates `gnunix-desktop`'s out-of-
box session) updates:

| Before | After |
|---|---|
| `pgrep -x sway` exists | `pgrep -x Hyprland` exists |
| `${XDG_RUNTIME_DIR}/wayland-*` socket exists | `${XDG_RUNTIME_DIR}/hypr/*.socket` AND `${XDG_RUNTIME_DIR}/wayland-*` exist |
| `swaymsg -t get_version` returns 0 | `hyprctl version` returns 0 |
| portal: `xdg-desktop-portal-wlr` running | portal: `xdg-desktop-portal-hyprland` running |

`tests/installer/profile-hyprland.sh` becomes a first-class PR/push
gate (was nightly-only); `tests/installer/profile-sway.sh` moves to
the nightly/tag-build gate. `profile-labwc.sh` stays nightly.

## Rationale

### Why amend ADR-009 instead of writing it from scratch

The substrate decision in ADR-009 — Wayland-only, greetd + tuigreet,
dbus/elogind/compositor from nixpkgs into the system profile, no X11
in the base — is unchanged. Only the compositor name changes. An
amendment-with-explicit-references keeps the original rationale
discoverable and lets a future reader trace the evolution
(*"why isn't this Sway anymore?"*) without spelunking commit history.

This mirrors how [ADR-016](ADR-016-ci-split-build-and-validation.md)
amended ADR-008 instead of replacing it.

### Why not keep Sway as the pre-baked default and offer Hyprland as a variant

Considered. The pre-baked compositor is what `gnunix-desktop`
downloaders see when they boot the published `.img.zst` / `.tart.zst`.
That artifact is the project's "default desktop experience"
business card — it should reflect what the maintainer actually
endorses and uses.

A counter-argument: Sway is more conservative and works on more
hardware. Mitigation: anyone who wants Sway can pick it in the
installer TUI; the published Sway path is one extra step
(boot installer → desktop → sway), not a removed option.

### Virtio-gpu reliability

Hyprland's GPU expectations are higher than Sway's, particularly
around explicit sync and damage tracking. Two concrete defenses:

- `env = WLR_NO_HARDWARE_CURSORS,1` in the starter config (visible
  cursor on virtio-gpu).
- `decoration { blur { enabled = false } }` on first boot. The blur
  is what most reliably breaks on weak GPUs; turning it off ships
  a smoother out-of-box experience. Users with capable hardware
  flip it on by editing one line.
- `tests/wayland-session.sh` runs against Tart on every PR. If
  Hyprland regresses on virtio-gpu, the test catches it before
  shipping.

### Effort estimate

This ADR is implemented as a single PR (PR-5 in the refactor stack):

- Edit `images/gnunix-desktop/build.sh` to swap three nix-env
  package names.
- Write the starter `/etc/hypr/hyprland.conf` (~50 lines).
- Edit `start-wayland-session.sh`: one line.
- Update `tests/wayland-session.sh`: ~6 line changes.
- Rewrite `desktop-sway.sh` profile to pull-at-install (mirrors
  `desktop-hyprland.sh`'s existing structure).
- Extract `desktop-common.sh` helper from the three profile
  scripts.
- Rebuild `gnunix-desktop` and verify `tests/wayland-session.sh`
  passes against Hyprland.

No kernel rebuild required (Hyprland uses the same drm/virtio-gpu
path as Sway). Incremental Nix work on top of `gnunix-minimal`,
~30 min per iteration on the macOS dev box.

## Consequences

### User-visible

- The published `gnunix-desktop-<arch>-<ver>.{img,tart}.zst`
  artifact boots into Hyprland on first run. Existing users
  upgrading from 0.1.0 see a different default compositor; this
  is signaled in the release notes.
- The default starter keybinds change (i3-style → Hyprland-style).
  `SUPER+RETURN` still opens a terminal; tiling commands differ.
  Documented in `docs/runbooks/hyprland-quick-reference.md`.
- Users who prefer Sway pick it during install. No regression in
  capability; one extra screen.

### Maintenance

- One less compositor pre-baked into a published image (Sway no
  longer in `gnunix-desktop`'s closure). Marginal CI time savings.
- Three compositor profile scripts converging on `desktop-common.sh`
  reduces drift. Adding a fourth compositor (river, niri, …) in
  the future is now copy-paste-plus-one-config.

### Forward references

`docs/adrs/ADR-009-wayland-stack.md` gains a one-line header:

```
**Amended by:** ADR-020 (default compositor switched to Hyprland;
Sway demoted to an optional installer profile).
```

The body of ADR-009 is otherwise untouched (historical fidelity).

`CLAUDE.md`'s locked-decisions table appends a row for ADR-020 and
updates the ADR-009 row to: *"Hyprland compositor (default) + greetd;
sway and labwc available as optional installer profiles. Amends
ADR-009."*

## Out of scope

- **River, niri, other wlroots compositors** as installer
  profiles. Possible follow-up; adding one is now mechanical
  (copy `desktop-hyprland.sh`, swap package name, seed config).
  No demand yet.
- **Hyprland-specific tooling** (hyprlock, hypridle,
  hyprpaper-as-default). The starter config uses upstream
  defaults only; bundling a curated set is a follow-up.
- **Removing greetd/tuigreet** in favor of a Hyprland-native
  greeter (regreet, etc.). greetd works fine; not changing now.
- **Theming.** No project-wide theme. Users theme their own.

## Open questions

1. **Default keybind set.** The starter config uses a minimal,
   discoverable set. Whether to ship a more elaborate "developer
   workstation" keybind preset (workspace-per-monitor, scratchpads,
   etc.) is a follow-up — easier to extend than to retract.
2. **Animations on by default?** Currently yes (upstream defaults).
   If Tart smoke tests show flicker, gate behind a runtime
   detection. Likely fine; revisit on first user complaint.
3. **Migration story for 0.1.0 → 0.2.0 users.** The release notes
   explain the compositor change. Users who scripted Sway-specific
   keybinds will need to port. Not in the install path; documented.
