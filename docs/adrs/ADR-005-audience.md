# ADR-005: Audience — developer workstation, this Mac first

**Status:** Accepted
**Date:** 2026-05-10

## Decision

The target user is a **single developer running on Apple Silicon under Tart**. No server use cases, no multi-machine fleets, no enterprise management.

## Rationale

- Constrains scope. We don't need: cluster orchestration, fleet provisioning, telemetry, multi-tenant security, A/B updates.
- Validates the "no service supervisor" choice (ADR-001) — a dev workstation tolerates manual restarts.
- Keeps the image lineage simple: one base, a few variants, all consumed locally.

## Consequences

- Image distribution is local-only in early phases. OCI-registry push (Phase 6) is *optional* and only added if a second machine actually needs it.
- Validation is interactive (boot the VM, log in, check the session). No automated fleet rollout testing.
- Security posture: assume a trusted single user. No hardening beyond Linux defaults until there's a concrete threat model.

## Revisit when

- A second person wants to run the image → add registry push.
- We want to use this on bare-metal hardware → reassess kernel config and bootloader.
