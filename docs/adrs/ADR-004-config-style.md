# ADR-004: Configuration style — plain Nix profiles + home-manager

**Status:** Accepted
**Date:** 2026-05-10

## Decision

User-visible configuration is managed by **`home-manager`** (per-user declarative Nix). System-level config that *must* live outside Nix (rc.d, fstab, kernel cmdline) is hand-curated in `images/lfs-core/etc/`.

**NixOS modules are explicitly out of scope.**

## Rationale

- The "static base, dynamic userland" principle: NixOS modules push system-level state back into the Nix world, which is exactly what we want to avoid in this architecture.
- If we wanted NixOS modules, we'd run NixOS — there'd be no point in the LFS base.
- home-manager is the right tool for the layer that *does* belong in Nix: per-user dotfiles, app sets, compositor config.

## Consequences

- No `configuration.nix` at the system level.
- Each user has a `home.nix` (under `~/`) composed from `bundles/*.nix`.
- System changes go through the rc.d scripts and the LFS rebuild pipeline; user changes go through `home-manager switch`.

## Out of scope

- NixOS modules: violates the architectural split.
- Flakes-as-system-config: same reason; flakes for *bundles* are fine.
