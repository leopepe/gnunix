# ADR-019: Image lineage roles, installer pivot, and finishing the rename

**Status:** Proposed
**Date:** 2026-05-15
**Extends:** [ADR-013](ADR-013-rename-to-gnunix.md), [ADR-015](ADR-015-installer-and-sessions.md)

## Context

After [ADR-013](ADR-013-rename-to-gnunix.md) the lineage on paper is:

```
gnunix-builder → gnunix-base → gnunix-nix → gnunix-desktop → gnunix-installer
                                                                 (variants/…)
```

Three things in that picture have become incoherent:

1. **The rename is half-done.** `gnunix-nix` is the directory and
   build-target name; "gnunix-minimal" is what every doc, runbook,
   and installer profile actually calls it (see e.g.
   `tests/installer/README.md` line 13: *"gnunix-nix (a.k.a.
   gnunix-minimal)"*). Two names for one thing.
2. **The installer is layered on the wrong image.**
   `gnunix-installer` clones `gnunix-desktop` and carries the full
   Sway/waybar/portal stack as its **live environment**, then rsyncs
   that whole thing onto every target — including users who picked
   the `minimal` profile. Wasteful both ways: minimal-profile installs
   ship 1.5 GB of unused compositor; desktop-hyprland/labwc installs
   pay for a Sway closure they don't use and *also* pull their chosen
   compositor at install time.
3. **The installer TUI doesn't match the mental model users have.**
   Today's flow presents four flat options
   (`minimal` / `desktop-sway` / `desktop-hyprland` / `desktop-labwc`).
   Users think in two questions: "minimal or desktop?" and (if desktop)
   "which compositor?". The flat radio buries the second question.

[ADR-018](ADR-018-artifact-taxonomy.md) establishes `gnunix-minimal`
as the release-dependency anchor — which makes the right place to
layer the installer obvious: on top of `gnunix-minimal`, not
`gnunix-desktop`. This ADR commits to that pivot.

## Decision

### 1. Finish the rename: `gnunix-nix` → `gnunix-minimal`

Tree-wide rename. The image's identity is "the minimal end-user
product" — Nix is *how* it's minimal-but-useful, not what it *is*.

Scope:

- `images/gnunix-nix/` → `images/gnunix-minimal/`
- `tools/build-all.sh` case `gnunix-nix)` → `gnunix-minimal)`
- `tools/manifest.json` keys referencing `gnunix-nix`
- `.github/workflows/build.yml` job names, artifact names, asset paths
- `.github/workflows/release.yml` body text and globs
- `tests/nix-smoke.sh` → `tests/minimal-smoke.sh`
- `docs/architecture.md` lineage diagram + phase table
- `CLAUDE.md` references in the "Phase status" section
- `images/installer/*.sh` and `images/installer/README.md` strings
- `runbook.md` and `docs/runbooks/*.md` mentions

Pre-rename historical ADRs (001–012) keep `lfs-nix` as part of
recording the pre-rename world, exactly as ADR-013 already did for
the first rename. [ADR-013](ADR-013-rename-to-gnunix.md) gains a
one-line amendment header pointing at this ADR for the second
rename.

The build artifacts coming out of the renamed image use the new name
starting from version 0.2.0: `gnunix-minimal-<arch>-<ver>.img.zst`.

### 2. Installer pivots to layer on `gnunix-minimal`

The installer is rebuilt to use `gnunix-minimal-<ver>` as its parent
image, not `gnunix-desktop-<ver>`. Consequences:

- **The live environment is text-only.** No Sway, no Hyprland, no
  greetd, no Wayland. The ISO boots into a `gnunix-minimal` rootfs
  with a TTY login on tty1.
- **All compositor installs are pull-at-install.** sway, hyprland,
  and labwc all come from `cache.nixos.org` via `nix-env -iA` during
  the per-profile post-install hook. There is one code path; no
  "this profile is offline, this one isn't" special-casing.
- **Network is required for any `desktop-*` profile.** This is a
  scope shift from [ADR-015](ADR-015-installer-and-sessions.md)
  which sold "minimal + sway work offline" as a feature. We trade
  that for code-path consistency and a much smaller ISO. The TUI
  warns about the network requirement on the compositor-selection
  screen.
- **`minimal` still works offline.** The minimal-profile install is
  pure rsync — the live rootfs *is* the target rootfs minus the
  installer scaffolding. No network needed.

### 3. Lineage roles after the pivot

```
gnunix-builder                                       (build-time only)
   │
   ▼
gnunix-base                          published (.img.zst, .tart.zst)
   │
   ▼
gnunix-minimal                       published; CI release-dep anchor
   │
   ├──────────────────┬──────────────────────┐
   ▼                  ▼                      ▼
gnunix-desktop    gnunix-installer       variants/<platform>/
published         published (.iso)       per-platform packagers
(Hyprland         live env = text-only   per ADR-010
 pre-baked        gnunix-minimal +
 per ADR-020)     TUI installer
```

`gnunix-desktop` and `gnunix-installer` are now **siblings**, both
layered on `gnunix-minimal`. Neither depends on the other.

`gnunix-desktop` continues to ship as a published image because
"boot a GNUnix Hyprland desktop VM in 30 seconds" is a real audience
(developers wanting a turnkey VM, Tart import on macOS, qemu try-out,
cloud deploys) — see [ADR-018](ADR-018-artifact-taxonomy.md).

### 4. Installer TUI: edition → compositor → identity

The TUI flow:

```
1. Welcome screen
2. Target disk           (lsblk → menu of block devices ≥ 8 GB)
3. Edition               ( ) minimal
                         (*) desktop
4. Compositor            shown only if Edition = desktop
                         (*) hyprland   — dynamic tiling + animations (DEFAULT)
                         ( ) sway       — tiling, i3-style
                         ( ) labwc      — stacking, Openbox-style
                         [network required — closure pulled from cache.nixos.org]
5. Identity              hostname, username, password (×2)
6. Confirm               Disk, Edition, Compositor (if any), Hostname, User
                         Proceed? [Y/N]
7. Execute (with progress bars):
   a. partition + format
   b. mount target
   c. rsync live rootfs → target  (gnunix-minimal contents only)
   d. chroot + run profile script:
        - minimal:    create user, enable agetty on tty1
        - desktop-*:  create user, nix-env -iA nixpkgs.<compositor> +
                      portal + waybar + foot into the target's system
                      profile; enable greetd; seed compositor config;
                      add user to wheel/video/input/render/audio/seat
   e. grub-install + grub.cfg + fstab
   f. sync, unmount, done
```

**`VARIANT_ID`** in `/etc/os-release` on the installed system encodes
both halves: `minimal`, `desktop-hyprland`, `desktop-sway`,
`desktop-labwc`. (Identical to today's flat naming, for compatibility
with any tooling that reads it.)

### 5. Live-image greetd session menu — gone

The previous design (ADR-015) had greetd present three sessions at
the live boot: "Install GNUnix", "Try live (Sway)", "Shell". After
the pivot the live env has no compositor and no greetd. Replaced by:

- **getty on tty1** auto-launches `/usr/local/sbin/gnunix-installer`
  on login as root.
- **getty on tty2** sits at a normal root shell prompt for users
  who want to poke around before installing. Switch with
  Ctrl+Alt+F2.
- That's it. No greetd, no compositor, no session menu.

Concretely, the installer's `install-installer.sh` rewrites
`/etc/inittab` so:

```
1:2345:respawn:/usr/local/sbin/gnunix-installer-getty tty1
2:2345:respawn:/sbin/agetty 38400 tty2 linux
```

where `gnunix-installer-getty` is a tiny wrapper that runs `agetty
--autologin root --noclear tty1` and chains into the installer.

### 6. CI release-dependency uses `gnunix-minimal`

Per [ADR-018](ADR-018-artifact-taxonomy.md): CI's "first step" for
downstream layers is `tools/fetch-image.sh gnunix-minimal <ver>`,
not `gnunix-base`. The installer and desktop builds both start from
the fetched minimal.

### 7. What stays the same

- All compile-time hardening ([ADR-011](ADR-011-compile-time-hardening.md)).
- Module-first kernel ([ADR-012](ADR-012-module-first-kernel.md)),
  with the four `=m` additions from
  [ADR-017](ADR-017-live-iso-architecture.md).
- The Wayland-only display server policy ([ADR-009](ADR-009-wayland-stack.md)).
  This ADR does **not** revisit X11.
- The release flow ([ADR-008](ADR-008-renovate-and-release.md))
  modulo the taxonomy changes in [ADR-018](ADR-018-artifact-taxonomy.md).
- Locked-decisions table in `CLAUDE.md` — appended, not edited; new
  ADRs row, no row deleted.

## Consequences

### ISO size

The live ISO drops from ~1.5 GB (full desktop rootfs in the live
image) to ~400–600 MB (gnunix-minimal rootfs in the live image).
Pendrives down from "16 GB+" to "any USB stick you can find".

### Install-time network requirement

Any `desktop-*` install needs network reachability to
`cache.nixos.org`. Documented prominently on the compositor-selection
TUI screen and in `docs/runbooks/install.md`. Users on disconnected
networks pick `minimal` and `nix-env` the rest in later.

### Smaller installer build

`gnunix-installer-build` no longer carries Sway/portal/waybar. The
build VM provisions only:

- Installer TUI payload (`gnunix-installer` bash script + profiles).
- Initramfs builder dependencies (per ADR-017): xorriso,
  squashfs-tools, cpio, mtools, dosfstools.

Provisioning takes minutes, not "wait for Sway closure to pull".

### Profile script restructure

`images/installer/installer/profiles/`:

| File | Before | After |
|---|---|---|
| `minimal.sh` | unchanged (create user, enable getty) | unchanged |
| `desktop-sway.sh` | "Sway is already in the rootfs, just create user" | `nix-env -iA nixpkgs.sway` + portal-wlr + waybar + foot; create user; seed `~/.config/sway/config`; enable greetd |
| `desktop-hyprland.sh` | `nix-env -iA nixpkgs.hyprland` | same as before, but now the **default** profile (radio pre-selected) |
| `desktop-labwc.sh` | `nix-env -iA nixpkgs.labwc` | unchanged |

The four profile scripts become structurally similar (the desktop
ones diverge only on package name + config seed). A
`desktop-common.sh` helper hoists the shared steps (create user, add
to groups, enable greetd, install portal + waybar + foot). Each
profile script reduces to: source `desktop-common.sh`, pick the
compositor, drop the starter config.

### Tests

- `tests/installer/profile-sway.sh` — semantics unchanged, but the
  underlying machinery shifts from "verify Sway binaries are in the
  rootfs" to "verify Sway closure was pulled into the target's
  system profile".
- `tests/installer/profile-hyprland.sh` and
  `tests/installer/profile-labwc.sh` — same checks as before, now
  treated as first-class (not "nightly only").
- `tests/installer/profile-minimal.sh` — unchanged.
- New: `tests/installer/iso-boot.sh` (per ADR-017) — boots the live
  ISO, asserts the installer TUI auto-launches on tty1.

The PR/push gate runs `minimal` + `desktop-hyprland` (the new
defaults) instead of `minimal` + `desktop-sway`. `desktop-sway` and
`desktop-labwc` move to the nightly / tag-build gate.

### Documentation

- `docs/runbooks/install.md` (new) — end-user "how to flash a USB
  and install" guide, including the network-required warning.
- `docs/runbooks/build-installer.md` (new) — maintainer "how the
  installer ISO is produced" guide.
- `docs/architecture.md` lineage diagram updated to the
  siblings-of-minimal shape.
- `CLAUDE.md` locked-decisions table appends ADR-017, 018, 019.

## Out of scope

- **Offline desktop install.** Possible as a future ADR if demand
  appears (bundle the Hyprland closure into the ISO as a `nix-store
  --import`-able blob, opt-in via TUI). Not in v1.
- **Encrypted root** (LUKS) — ADR-015 already noted this is deferred.
- **Multi-disk / RAID / LVM** — ADR-015 already noted this is
  deferred.
- **Live-environment compositor.** The live env is text-only by
  design. If a user wants to "demo GNUnix with Hyprland running",
  they download `gnunix-desktop-<arch>-<ver>.img.zst` and boot that
  in a VM — that's the use case `gnunix-desktop` is published for.

## Open questions

1. **Default compositor pre-selection.** Hyprland is the default in
   the TUI radio. Confirmed by maintainer preference (May 2026); if
   the choice changes later, edit one line in
   `images/installer/installer/gnunix-installer`.
2. **Auto-login as root on tty1.** The installer-getty wrapper
   auto-logs-in as root because the live env has no other user.
   Acceptable on a live install medium; would be unacceptable on
   an installed system. The `gnunix-installer-getty` script is
   live-only, never copied to the target.
3. **Per-compositor sanity check at install time.** After
   `nix-env -iA` succeeds, should we test-run the binary in the
   chroot to fail fast on a broken closure? Cheap (one
   `nix-build --check` or `command -v`), useful for debugging
   flaky CDN pulls. Likely yes; settle during PR-4 implementation.
