# ADR-004: Configuration style — plain Nix profiles + home-manager

**Status:** Superseded by [ADR-025](ADR-025-declarative-system-flakes.md)
**Date:** 2026-05-10
**Superseded:** 2026-09-13 — ADR-025 replaces this ADR. Its *Out of scope* line "Flakes-as-system-config: same reason" conflated a NixOS module system (which owns init, services, users and mounts) with a flake producing a `pkgs.buildEnv` (which is a symlink tree and owns none of them). Banning both under one rationale left `nix-env -iA` against a moving `nix-channel` as the only permitted way to fill a system profile. The architectural split defended here is correct and survives; so do the home-manager decision for the per-user layer, the hand-curated system files, and the ban on NixOS modules — all absorbed into ADR-025. Only the treatment of flakes was wrong.

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
