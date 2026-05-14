# ADR-003: Nix in multi-user daemon mode

**Status:** Accepted
**Date:** 2026-05-10

## Decision

Install Nix in **multi-user mode**: `/nix` owned by root, `nixbld1..N` build users, `nix-daemon` running as a service, builds sandboxed.

## Rationale

- Sandboxed builds match nixpkgs CI behavior — fewer "works on my machine" surprises.
- `/nix/store` permissions prevent users from corrupting cached derivations.
- Multi-user is the default Nix install mode and the path with the most documentation/tooling.

## Consequences

- `images/lfs-core/etc/rc.d/rc.nix-daemon` starts the daemon.
- Build users created during `nix-bootstrap.sh` (Phase 3).
- Kernel must support user namespaces and cgroups v2 (already required for sandbox).

## Out of scope

- Single-user mode: weaker isolation, harder to share builds across users.
- Skipping Nix: the entire userland strategy depends on it.
