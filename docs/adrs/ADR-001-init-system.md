# ADR-001: Init system — sysvinit with BSD-style rc.d

**Status:** Accepted
**Date:** 2026-05-10

## Context

The base image needs PID 1 and a way to bring up services at boot. Options:

- **systemd** — most compatible with desktop Linux today; pulls in logind, networkd, resolved, journald.
- **OpenRC** — Gentoo's, lightweight, dependency-aware service scripts.
- **s6 / dinit / runit** — supervision-tree inits, restart-on-crash, lightweight.
- **sysvinit + BSD-style rc.d** — Slackware approach: `/etc/rc.d/rc.S`, `rc.M`, `rc.K`, `rc.6`, plus per-service `rc.<name>` enabled by `chmod +x`. No SysV runlevel symlink directories. No service supervision.

## Decision

**sysvinit with BSD-style `/etc/rc.d/` scripts.**

`/etc/inittab` defines the runlevels and points at `rc.S` (sysinit) and `rc.M` (multiuser). Per-service scripts are individual files in `/etc/rc.d/`, executable iff enabled.

## Rationale

- **Static base, dynamic userland.** Anything that needs to evolve quickly belongs in Nix, not in PID 1. The base needs to boot and stay out of the way.
- **No policy in PID 1.** systemd's coupling to logind, dbus, and userspace policy is exactly what we want to avoid. Init does init.
- **Auditable.** rc.d scripts are short shell. A new contributor can read the entire boot sequence in 20 minutes.
- **Single-user developer workstation.** No service-restart SLAs, no fleet orchestration concerns. Crash-restart is over-engineering.
- **Slackware's track record.** This pattern has been stable for 30 years.

## Tradeoffs accepted

- No automatic restart-on-crash for system services. Acceptable for a dev workstation; revisit only if it bites in practice.
- No dependency graph for services. Order is encoded in `rc.M` (linear), which is fine because the base has few services.
- Less ecosystem support — most distro packaging assumes systemd unit files. We translate to `rc.<name>` scripts manually for the small set of services in the base.

## Consequences

- `rc.d/` scripts checked into `images/lfs-core/etc/rc.d/`.
- Services in the base layer: `rc.dbus`, `rc.elogind`, `rc.sshd`, `rc.nix-daemon`, `rc.network`. Compositor/session services live in the Nix layer, not here.
- No `systemctl`. Manage services with `chmod ±x /etc/rc.d/rc.<name>` and direct invocation.

## Out of scope (not chosen)

- systemd, OpenRC, s6, dinit, runit. Each fails one of: "no policy in PID 1," "static base," "auditable in 20 minutes," or "Slackware-simple."
