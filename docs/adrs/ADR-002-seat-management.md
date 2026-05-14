# ADR-002: Seat management — elogind

**Status:** Accepted
**Date:** 2026-05-10

## Context

Wayland compositors and many desktop apps require a "seat" abstraction that grants the logged-in user access to input devices and DRM. They expect the `org.freedesktop.login1` D-Bus API.

Options:

- **systemd-logind** — canonical, but requires systemd as PID 1 (rejected in ADR-001).
- **elogind** — standalone fork of logind, provides the same D-Bus API without systemd.
- **seatd** — minimal seat manager, *does not* provide the logind D-Bus API. Compositors with built-in seatd support work; portals and apps that expect logind do not.

## Decision

**elogind.**

## Rationale

- We need the `login1` D-Bus API for `xdg-desktop-portal`, GNOME/KDE-derived apps, and PAM integration (`pam_elogind`). seatd alone leaves gaps.
- elogind is packaged in nixpkgs and most distros, well-maintained.
- Compatible with sysvinit (ADR-001).

## Consequences

- `images/lfs-core/etc/rc.d/rc.elogind` starts the elogind daemon.
- PAM stack includes `pam_elogind.so` to register sessions on login.
- Compositor (Phase 4) will pick up the seat via the standard `login1` D-Bus calls — no compositor-specific seat config needed.

## Out of scope (not chosen)

- systemd-logind: blocked by ADR-001.
- seatd alone: insufficient API surface for the desktop ecosystem we want.
