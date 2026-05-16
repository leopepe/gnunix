# ADR-022: Add COSMIC as a fourth installer compositor profile

**Status:** Proposed
**Date:** 2026-05-16
**Amends:** [ADR-015](ADR-015-installer-and-sessions.md), [ADR-020](ADR-020-compositor-switch-hyprland.md)

## Context

[ADR-015](ADR-015-installer-and-sessions.md) locks the installer's
profile set and [ADR-020](ADR-020-compositor-switch-hyprland.md) locks
the three compositor options offered at install time:

```
Compositor:
  (*) hyprland   — dynamic tiling + animations (DEFAULT)
  ( ) sway       — tiling, i3-style
  ( ) labwc      — stacking, Openbox-style
```

[`CLAUDE.md`](../../CLAUDE.md) § "Guiding philosophy" further locks
**"no desktop environment in the base image"** — GNOME and KDE are
explicitly out of scope because both pull in `systemd --user` /
`graphical-session.target` and a session-manager surface our sysvinit
substrate (ADR-001) can't satisfy without significant porting work.

Since ADR-020 was written, **COSMIC** (System76's Rust Wayland stack
— `cosmic-comp` + `cosmic-session` + `cosmic-settings` + the COSMIC
apps) reached `epoch-1.0.0` (verified on 2026-05-16 against the
`nixos-25.11` channel pinned in `tools/manifest.json`). It occupies an
interesting niche our existing locked decisions don't cover:

- It is the only modern *desktop environment* that was **designed from
  day one to be init-agnostic**. `cosmic-session` brings up its own
  D-Bus user bus via the standalone `dbus-run-session` rather than
  delegating to `systemd --user` / `graphical-session.target`. The
  nixpkgs `package.nix` confirms this:
  `cosmic-session` `buildInputs = [ bash ]` + `dbus`; no systemd
  anywhere.
- It uses the standard `org.freedesktop.login1` D-Bus API, which
  `elogind` ([ADR-002](ADR-002-seat-management.md)) already provides.
- Upstream provides a `wayland-sessions/cosmic.desktop` file via
  `passthru.providedSessions = [ "cosmic" ]`, so greetd + tuigreet
  pick it up through the same mechanism Sway / Hyprland / labwc use
  today.

This means we can add COSMIC without violating ADR-001 (no systemd),
ADR-002 (elogind), ADR-009 (Wayland substrate), or the "no DE in the
base image" rule — provided we follow the same **install-time pull**
pattern ADR-015/019 established for the other compositor profiles
rather than pre-baking COSMIC into any base or minimal image.

Surfaced as an ADR proposal in [issue #13](https://github.com/leopepe/gnunix/issues/13).

## Decision

### `desktop-cosmic` joins as a fourth compositor profile

The installer's "Wayland compositor:" radiolist grows one row:

```
Compositor:
  (*) hyprland   — dynamic tiling + animations (DEFAULT)
  ( ) sway       — tiling, i3-style
  ( ) labwc      — stacking, Openbox-style
  ( ) cosmic     — System76 COSMIC desktop (init-agnostic, polished)
```

The default selection does **not** change — hyprland remains the
reference compositor and the pre-baked default in `gnunix-desktop`
per ADR-020. COSMIC is opt-in at install time.

### Profile script

`images/installer/installer/profiles/desktop-cosmic.sh` mirrors the
shape of the existing profile scripts (most closely
`desktop-hyprland.sh`):

1. Create the unprivileged user, add to
   `wheel,video,input,render,audio,seat,nixbld`.
2. Ensure `nix-daemon` is running.
3. `nix-env -p /nix/var/nix/profiles/system -iA` the COSMIC closure
   from `nixpkgs`:
   - **Core session/compositor**: `cosmic-comp`, `cosmic-session`,
     `cosmic-settings-daemon`, `cosmic-settings`, `cosmic-panel`,
     `cosmic-launcher`, `cosmic-applets`, `cosmic-bg`, `cosmic-osd`,
     `cosmic-workspaces-epoch`, `cosmic-randr`, `cosmic-protocols`.
   - **Default apps**: `cosmic-term`, `cosmic-files`, `cosmic-edit`.
   - **Portal**: `xdg-desktop-portal-cosmic`.
   - **Icons / theming**: `cosmic-icons`.
   `cosmic-greeter` is **not** included — greetd + tuigreet remains
   the greeter per ADR-009.
4. Replace `/usr/local/bin/start-wayland-session.sh` with a wrapper
   that `exec`s `start-cosmic` (the nixpkgs-shipped launcher script
   that internally does `dbus-run-session cosmic-session`).
5. Install the `wayland-sessions/cosmic.desktop` file from
   `${cosmic-session}/share/wayland-sessions/` into
   `/usr/local/share/wayland-sessions/` so a future regreet-style
   selector can pick the COSMIC session.
6. Seed `~/.config/cosmic/` with a minimal starter config (panel
   layout + an output-scaling default that survives virtio-gpu).
7. `chmod +x /etc/rc.d/rc.greetd` to enable the greeter at next boot.

### Bundle

A new `bundles/cosmic.nix` exposes the COSMIC closure as a pure
function of `pkgs` (per `CLAUDE.md` § Nix conventions):

```nix
{ pkgs }: with pkgs; [
  cosmic-comp cosmic-session cosmic-settings cosmic-settings-daemon
  cosmic-panel cosmic-launcher cosmic-applets cosmic-bg cosmic-osd
  cosmic-workspaces-epoch cosmic-randr cosmic-protocols cosmic-icons
  cosmic-term cosmic-files cosmic-edit xdg-desktop-portal-cosmic
]
```

The profile script references the bundle via `nix-env -f <bundle>`
or expands the package list inline — to be decided in implementation
based on whether the other profile scripts converge on a bundle
pattern (none use bundles today).

### TUI changes

`images/installer/installer/gnunix-installer` § `gather_inputs_interactive`:

- Add the fourth row to the compositor radiolist (see Decision §
  above for the exact label).
- Update the network-required msgbox text to mention COSMIC alongside
  Hyprland and labwc as profiles that require network at install time
  (COSMIC pulls ~est. 800 MB–1.2 GB uncompressed from `cache.nixos.org`).

The screen title stays **"Wayland compositor:"**. COSMIC is a desktop
environment in marketing terms, but at the level the installer cares
about (a `wayland-sessions/*.desktop` file pointing at a launcher)
the existing label is accurate and the smaller diff into existing
tests / docs is the lower-risk choice.

### Testing

Three additions, no changes to existing tests beyond appending rows
in tables/iterators:

| File | Status |
|---|---|
| `tests/installer/tui-scenarios/desktop-cosmic.exp` | **new** — drives radiolist row 4; mirrors `desktop-labwc-nextspace.exp` |
| `tests/installer/profile-cosmic.sh` | **new** — installer-test entry-point (shim around `scripts/run-installer-test.sh cosmic`) |
| `scripts/validate-installed.sh` | **modify** — add `desktop-cosmic` case asserting `$SP/bin/cosmic-comp`, `$SP/bin/start-cosmic`, `/usr/local/share/wayland-sessions/cosmic.desktop`, `~/.config/cosmic/` skeleton, user-in-groups |
| `tests/installer/tui-interactions.sh` | **modify** — one row in the `scenarios` variable |
| `tests/installer/run-all.sh` | **modify** — add cosmic to the iteration list |
| `tests/installer/README.md` | **modify** — table rows |

A standalone `tests/wayland-session-cosmic.sh` (analogous to the
existing `wayland-session.sh` for Hyprland) is **out of scope** for
this ADR — it would require a published image, and COSMIC isn't
pre-baked into one. Tracked as a follow-up for after we have a
`desktop-cosmic` installer test passing.

### CI

The implementation PR re-adds a `gnunix-installer` test slot for
`desktop-cosmic` in the `installer-test` matrix once PR-3b.2 lands the
qemu+KVM driver (per ADR-021). Today the matrix is dormant (PR-3b.1
fetch-foundation); cosmic joins the matrix at the same time as the
other desktop-* profiles return to active CI.

## Rationale

### Why amend ADR-015 + ADR-020 instead of writing a fresh "compositor list" ADR

Both ADRs explicitly enumerate the profile / compositor set they lock.
Adding a fourth row touches both, but neither's *substrate decision*
changes (installer architecture, default compositor). An amendment-with-
explicit-references keeps the original rationale discoverable
(*"why these four?"*) without spelunking commit history, the same
pattern ADR-020 used to amend ADR-009 and ADR-019 used to extend
ADR-013 + ADR-015.

### Why COSMIC and not GNOME or KDE

`CLAUDE.md` § "No desktop environment in the base image" rules out
GNOME and KDE on architectural grounds:

- GNOME's session manager is `gnome-session`, which expects
  `systemd --user` and the `graphical-session.target` to exist. Without
  systemd we'd ship a non-trivial shim and re-test every release.
- KDE Plasma has a smaller systemd surface but increasingly assumes
  `systemd --user` for `plasma-workspace`, `kglobalaccel`, etc.
  Plasma 6 deepened this.

COSMIC was designed by System76 specifically to avoid that entanglement
(their popular distribution, Pop!_OS, uses systemd everywhere, but they
designed COSMIC to be portable across init systems anticipating their
future immutable / non-systemd targets). The result: a polished
DE-grade experience on a sysvinit substrate without porting work.

This is a one-off architectural fit, not a precedent for "let's add
more DEs". If a future ADR proposes adding another DE, the test is the
same: does it require systemd `--user` or not? If yes, rejected on
ADR-001 grounds; if no, can be discussed.

### Why pull-at-install rather than pre-bake a `gnunix-desktop-cosmic` image

Considered (Option 2 in issue #13). Rejected:

- Doubles published-artifact surface and per-release download size
  for a profile we expect to be a minority choice (Hyprland is the
  reference and the maintainer's daily driver per ADR-020).
- Forces the choice at *download* time instead of *install* time.
  Loses the install-time flexibility ADR-015 was built around.
- Doesn't match the existing pattern for Sway / labwc /
  labwc-nextspace — those are all install-time pulls and the
  installer is the supported way to get them.

### Why not defer until COSMIC 1.x is more mature

(Option 3 in issue #13.) The nixpkgs entry is at `epoch-1.0.0`, not
pre-1.0 as the issue assumed. nixpkgs upstream ships nixosTests for
`cosmic`, `cosmic-autologin`, and `cosmic-noxwayland` — meaning the
test surface is already maintained by people who aren't us. Deferring
means users who want it install COSMIC by hand outside the supported
set, and we miss the architectural-fit moment (it's the only modern DE
that doesn't need systemd; that may not stay true if a future
`cosmic-session` releases gains a systemd-only feature).

If COSMIC ever introduces a hard `systemd --user` dependency, this
ADR is revisited — either the profile is removed or a shim is written
in a new ADR. Open question §1 below tracks this.

### Why exclude `cosmic-greeter`

`cosmic-greeter` is COSMIC's native greetd-compatible greeter. We
keep `tuigreet` (ADR-009) for two reasons:

1. Greetd is the layer that owns vt1 *before* any session starts. Per
   ADR-009 it's substrate, not user-visible chrome. Switching the
   greeter per profile would mean per-profile greetd configs and a
   per-profile install path for the greeter binary.
2. `tuigreet` is a tiny ncurses dialog. Selecting a session is the
   only thing the greeter does; the per-session UI lives inside the
   compositor. There's no UX win from a graphical greeter pre-login.

If a future maintainer wants graphical greeters, that's a separate
ADR.

### Effort estimate

This ADR is paired with one implementation PR (~14 files touched,
documented in the **Testing** subsection above plus the bundle +
profile script + TUI radiolist edit):

- New: `bundles/cosmic.nix`, `images/installer/installer/profiles/desktop-cosmic.sh`,
  `tests/installer/tui-scenarios/desktop-cosmic.exp`,
  `tests/installer/profile-cosmic.sh`.
- Modify: `images/installer/installer/gnunix-installer` (one radiolist
  row + the network msgbox text), `scripts/validate-installed.sh`
  (new case), `tests/installer/tui-interactions.sh` (one row),
  `tests/installer/run-all.sh` (one entry),
  `tests/installer/README.md` (two table rows).
- Smoke: run `tests/installer/tui-interactions.sh` (must show 8/8),
  then the existing `profile-hyprland.sh` (regression check: hyprland
  still the default), then `profile-cosmic.sh` against a freshly built
  `gnunix-installer-<ver>` image.

No kernel rebuild; no `gnunix-base` rebuild; no `gnunix-minimal`
rebuild; no `gnunix-desktop` rebuild. The only build artifact
affected is the live `gnunix-installer` ISO, which gets a tweaked
payload (TUI + one new profile script + the cosmic.desktop session
file).

## Consequences

### User-visible

- Installer offers a fourth compositor row. Users who pick `cosmic`
  see ~est. 800 MB–1.2 GB of `cache.nixos.org` traffic during install
  (similar order of magnitude to Hyprland; COSMIC's closure is
  comparable in size).
- A successful `desktop-cosmic` install boots into greetd → tuigreet
  → select "cosmic" → COSMIC session.
- The published `gnunix-desktop-<arch>-<ver>.{img,tart}.zst` artifact
  is **unchanged**. Users who download the pre-baked desktop image
  still get Hyprland.

### Maintenance

- One more compositor profile script to keep aligned with the
  others when ADR-009/020 substrate changes (greetd config, session
  wrapper, group membership). ADR-020 § "Maintenance" already
  observes that converging profile scripts onto `desktop-common.sh`
  is the long-term plan; cosmic joins that convergence when it
  happens.
- One more closure to track for renovation. COSMIC's nixpkgs entries
  are auto-updated by the nixpkgs maintainers; we just consume them
  via the pinned channel.
- Tracking COSMIC's `epoch-1.x` cadence is mechanical via the pinned
  channel. A new `cosmic-session` release lands in the channel; our
  next pin bump picks it up. If a release ever introduces a
  `systemd --user` requirement (Open question §1), we have to
  revisit; today's check says it does not.

### ADR impact

- Amends [ADR-015](ADR-015-installer-and-sessions.md) — installer
  profile set grows from 4 (`minimal`, `desktop-sway`,
  `desktop-hyprland`, `desktop-labwc`) to 5
  (`minimal`, `desktop-sway`, `desktop-hyprland`, `desktop-labwc`,
  **`desktop-cosmic`**). Profile mechanism (whiptail TUI,
  install-time pull, per-profile script) unchanged.
- Amends [ADR-020](ADR-020-compositor-switch-hyprland.md) —
  installer compositor options grow from 3 to 4. Hyprland remains
  the reference and the **only** pre-baked option in `gnunix-desktop`.
- Does not touch [ADR-001](ADR-001-init-system.md),
  [ADR-002](ADR-002-seat-management.md),
  [ADR-009](ADR-009-wayland-stack.md),
  [ADR-019](ADR-019-image-lineage-and-installer-pivot.md). The
  substrate, seat management, Wayland stack, and lineage are all
  unchanged.

### Forward references

`ADR-015` and `ADR-020` each gain a header amendment line:

```
**Amended:** 2026-05-16 — ADR-022 (added desktop-cosmic profile;
  scope only — TUI mechanism + pre-baked default unchanged).
```

`CLAUDE.md`'s locked-decisions table:

- ADR-015 row: *"Live installer (`gnunix-installer`) + **5**
  Wayland-only profiles (`minimal`, `desktop-sway`, `desktop-hyprland`,
  `desktop-labwc`, `desktop-cosmic`); …"*
- ADR-020 row: *"Reference compositor switched from Sway to
  **Hyprland**. … Sway demoted to one of **four** optional installer
  profiles (sway / hyprland / labwc / cosmic), pulled at install
  time. (Amends ADR-009; amended by ADR-022.)"*
- New ADR-022 row appended.

`docs/architecture.md`:

- Locked-decisions section gains an ADR-022 line.
- Phase status row 4.5 (`gnunix-installer`) updates the profile
  enumeration from 4 to 5.

## Out of scope

- **Pre-baking COSMIC into a published image.** Considered and
  rejected (see Rationale § "Why pull-at-install"). If demand emerges
  later, a sibling image `gnunix-desktop-cosmic` is a one-line
  addition to the image-lineage; needs its own ADR.
- **`cosmic-greeter` as the installer's greeter** (see Rationale §
  "Why exclude `cosmic-greeter`"). Separate ADR if revisited.
- **`tests/wayland-session-cosmic.sh`** (analog of the existing
  `wayland-session.sh` for Hyprland). Needs a built `gnunix-desktop-cosmic`
  image or a CI path that installs COSMIC fresh in each run.
  Follow-up.
- **GNOME / KDE / other DEs.** Out of scope per `CLAUDE.md` "no DE
  in the base image" and the systemd-`--user` test articulated in
  Rationale § "Why COSMIC and not GNOME or KDE".
- **Migration from a `desktop-hyprland` install to `desktop-cosmic`.**
  The installer is single-shot per ADR-015. Users wanting to switch
  reinstall or `nix-env -iA nixpkgs.cosmic-comp …` by hand.

## Open questions

1. **Future `systemd --user` requirement in COSMIC.** Today
   `cosmic-session` uses `dbus-run-session` and does not depend on
   `systemd --user`. If a future `epoch-1.x` release introduces a
   hard requirement, the profile either gets a session-manager shim
   (new ADR) or is removed (amendment to this ADR). Tracked via the
   Renovate-style channel updates; this ADR is revisited at every
   `cosmic-session` major bump.
2. **Default keybinds / panel layout.** COSMIC ships sensible
   defaults; the starter `~/.config/cosmic/` skeleton sets only the
   things needed to survive virtio-gpu (output scaling, panel
   visible). Whether to ship a more elaborate "developer
   workstation" config is a follow-up.
3. **XWayland.** nixpkgs lists a `cosmic-noxwayland` test variant
   alongside `cosmic`; both work. We're Wayland-only (ADR-009), so
   the profile script does **not** install XWayland, but we don't
   actively block it for a user who installs it by hand. Confirm
   first install on real hardware doesn't surface a regression.

Architecture impact: see `docs/architecture.md` § Locked decisions.
