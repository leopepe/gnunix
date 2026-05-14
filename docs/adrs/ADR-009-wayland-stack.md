# ADR-009: Wayland stack — compositor, greeter, and system-service sourcing

**Status:** Accepted
**Date:** 2026-05-13

## Context

Phase 4 layers a Wayland graphical session on top of `lfs-nix-<ver>` to produce
`lfs-wayland-<ver>`. Three decisions are coupled and need to be settled together
because the choices constrain each other:

1. Which compositor.
2. Which greeter / login chain.
3. Where the daemons that wire it all together (dbus, elogind, greetd, the
   compositor itself) come from — built into the LFS base, or pulled from
   nixpkgs into a system Nix profile.

Phase 2 (lfs-core) intentionally deferred dbus and elogind ("Python/meson not
bootstrapped"), shipping disabled `rc.dbus` / `rc.elogind` scripts (`chmod -x`).
By Phase 3 (lfs-nix) we have a working multi-user Nix daemon (ADR-003), so
nixpkgs-sourced builds are now a viable path for the gap.

## Decision

### Compositor: **Sway**

wlroots-based tiling compositor. Mature, single-file config, runs cleanly on
`virtio-gpu` without GPU passthrough.

### Greeter: **greetd + tuigreet**

`greetd` supervises the login transaction; `tuigreet` is a TTY-based greeter
(works without GPU initially), which then `exec`s `sway` as the chosen user.

### System services: **installed from nixpkgs into `/nix/var/nix/profiles/system`**

`dbus`, `elogind`, `greetd`, `sway` (and a baseline of compositor utilities —
`foot`, `swaybg`, `wayland-utils`) are installed via:

```sh
nix-env -p /nix/var/nix/profiles/system -iA nixpkgs.<pkg> …
```

The Phase 4 rc.d scripts (`rc.dbus`, `rc.elogind`, `rc.greetd`) point at
`/nix/var/nix/profiles/system/bin/...` instead of `/usr/bin/...`.

## Rationale

### Compositor

- Sway is a wlroots reference consumer; what works in Sway tends to work in
  any wlroots compositor we might offer as a variant later.
- Virtual machines under Tart present `virtio-gpu`; Sway runs there without
  configuration.
- River, Hyprland, niri all considered — Sway has the lowest support cost
  for "first compositor that has to work everywhere". Variants (ADR forthcoming)
  can offer alternatives without changing the base.

### Greeter

- `greetd` is the minimal login manager that survived the lightdm/sddm/gdm
  pile-up. Plain config, no D-Bus required for greetd itself.
- `tuigreet` runs in a TTY, which means the *login prompt* works even before
  the GPU stack is up. Once the user logs in, greetd execs sway and the
  Wayland session takes over.

### Sourcing dbus/elogind/etc. from nixpkgs

The architecture doc (`docs/architecture.md`) lists dbus + elogind as
static-base components, but the Phase 2 build pipeline never got them built
(missing Python/meson at the time). Three options were considered:

1. **Retrofit them into lfs-core stages.** Honors the static-base intent.
   Cost: a full lfs-core rebuild (~6–10h) and a new pass on cross-built Python
   and meson, just to land two binaries.
2. **Source them from nixpkgs into a system Nix profile.** Cheap, sha256-pinned
   by the nixpkgs revision, deterministic. Trade-off: the binaries live under
   `/nix/...` not `/usr/...`, which softens (but does not abandon) the
   static-base / dynamic-userland split.
3. **Source them from nixpkgs via home-manager into a user profile.** Doesn't
   work for system daemons that need to run before any user has logged in.

We choose option 2. Justification:

- The CLAUDE.md heuristic ("if unsure, default to userland Nix") points here.
- dbus and elogind do change ABIs over time; pinning them to a nixpkgs channel
  inherits the security maintenance the upstream channel already provides,
  rather than us reimplementing it.
- The split is preserved in spirit: the **static base** still owns init,
  the kernel, libc, and the rc.d dispatch. The **dynamic userland** owns
  user-visible things — and the small daemons that bridge them.

The system profile (`/nix/var/nix/profiles/system`) is treated as
"essentially-static base": it changes only via deliberate Phase-4 rebuilds,
never via interactive `nix-env`.

## Consequences

- New files under `images/lfs-wayland/`:
  - `build.sh` (host orchestrator, mirrors `images/lfs-nix/build.sh`)
  - `install-wayland.sh` (in-VM installer)
  - `etc/rc.d/rc.dbus`, `rc.elogind`, `rc.greetd`, `rc.M`
  - `etc/greetd/config.toml`, `etc/sway/config`, `etc/pam.d/greetd`
- `rc.M` gains `run_if_enabled rc.greetd` after `rc.nix-daemon`.
- `tests/wayland-session.sh` validates: dbus + elogind daemons present and
  running, greetd binary on PATH, rc scripts enabled, user `user` exists,
  `virtio-gpu` DRM device present.
- Architecture doc updated: the dbus/elogind row is annotated "sourced from
  nixpkgs into `/nix/var/nix/profiles/system`, per ADR-009".

## Out of scope (not chosen)

- **NixOS modules**: blocked by ADR-004.
- **Building dbus/elogind from source in lfs-core**: rejected per rationale
  above. May revisit if a binary-reproducibility requirement appears that
  the nixpkgs channel can't satisfy.
- **River / Hyprland / niri as the default compositor**: candidates for
  variants under `images/variants/`.
- **xdg-desktop-portal**: needed for screen-sharing / file-pickers / etc.
  Adding it requires picking a backend (wlr, gnome, kde). Deferred to a
  Phase 4.1 follow-up; tracked in `docs/TODO.md`.
- **Full headless Wayland test**: the Phase 4 smoke test asserts daemons
  and binaries; actually rendering a frame through `virtio-gpu` from CI is
  a separate testing problem (likely `wlr-randr` + a screenshot diff) and
  is out of scope here.
