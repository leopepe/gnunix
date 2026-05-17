<p align="center">
  <img src="assets/gnunix-logo-v1.png" alt="GNUnix logo" width="640">
</p>

# GNUnix

<p align="center">
  <a href="https://github.com/leopepe/gnunix/releases/latest">
    <img alt="Latest release" src="https://img.shields.io/github/v/release/leopepe/gnunix?include_prereleases&sort=semver&logo=github">
  </a>
  <a href="https://github.com/leopepe/gnunix/tags">
    <img alt="Latest tag" src="https://img.shields.io/github/v/tag/leopepe/gnunix?sort=semver&logo=github">
  </a>
  <a href="https://github.com/leopepe/gnunix/blob/main/LICENSE">
    <img alt="License: BSD-2-Clause" src="https://img.shields.io/badge/license-BSD--2--Clause-blue?logo=github">
  </a>
  <a href="https://github.com/leopepe/gnunix/commits/main">
    <img alt="Last commit" src="https://img.shields.io/github/last-commit/leopepe/gnunix?logo=github">
  </a>
  <a href="https://github.com/leopepe/gnunix/graphs/contributors">
    <img alt="Contributors" src="https://img.shields.io/github/contributors/leopepe/gnunix?logo=github">
  </a>
  <a href="https://github.com/leopepe/gnunix/issues?q=is%3Aissue+is%3Aopen+label%3Abug">
    <img alt="Open bugs" src="https://img.shields.io/github/issues/leopepe/gnunix/bug?label=open%20bugs&logo=github">
  </a>
  <a href="https://github.com/leopepe/gnunix/actions/workflows/installer-tui-test.yml">
    <img alt="Installer TUI tests" src="https://github.com/leopepe/gnunix/actions/workflows/installer-tui-test.yml/badge.svg?branch=main">
  </a>
  <a href="https://github.com/leopepe/gnunix/actions/workflows/build.yml">
    <img alt="Build images" src="https://github.com/leopepe/gnunix/actions/workflows/build.yml/badge.svg?branch=main">
  </a>
</p>

Custom Linux distribution for developer workstations on Apple Silicon.

The name is a pun: **GNU**'s-Not-Unix meets **Nix**. The base layer is built
almost entirely from the GNU toolchain (Linux From Scratch, arm64);
the userland is managed by Nix. Read either as GNUnix (GNU + Nix) or as
"GN[U] Unix" — both apply.

- **Base:** Linux From Scratch (arm64), Slackware-style `sysvinit` + BSD `/etc/rc.d/`.
- **Userland:** Nix (multi-user) + home-manager. All apps, the Wayland compositor, dev tools.
- **Delivery:** Tart VM images. Linear image lineage from `gnunix-builder` → `gnunix-base` → `gnunix-minimal` → `gnunix-desktop` → platform variants.

## Philosophy

GNUnix is what you get when you let the 1990s and the 2020s argue for an
afternoon and write down the parts they both agreed on. The 1990s side
of the table is, unapologetically, **Slackware** — the oldest still-
maintained Linux distribution, named after the SubGenius pursuit of
*Slack*, and the spiritual ancestor of basically every design choice in
our base layer. Patrick Volkerding shipped a distro built on the radical
idea that the computer should do its job and then get out of your way so
you can pursue Slack. We are stealing that idea with both hands and a
getaway car. Praise "Bob."

The base is GNU and stays GNU. `coreutils`, glibc, GCC, `bash`,
`binutils` — compiled from source, doing exactly the thing they've done
well for thirty years. No `busybox` shrink-ray. No Rust rewrite of `cp`
that phones home to four telemetry endpoints before it can copy a file.
The Conspiracy would love for you to need sixteen background services
to print a directory listing; we refuse on principle.

PID 1 is `sysvinit` because PID 1 should be boring. There is `rc.S`,
`rc.M`, and a directory of `chmod +x`-toggled shell scripts, and that
is the whole show. No unit files. No D-Bus in init. No declarative
supervision tree. If you can read `sh`, you can read our boot path.
Volkerding worked this out in 1993 and "Bob" has not, to our knowledge,
sent a memo retracting it.

Everything that moves lives in `/nix/store`. Editors, browsers, language
toolchains, the Wayland compositor itself — pinned, reproducible,
blow-away-able. Break your config? `nix profile rollback`. Try a new
compositor? `nix shell nixpkgs#river`. Hate the result? Close the
terminal. Reproducibility is just Slack with receipts.

We ship Wayland, not X11 — substrate, not policy. `seatd`/`elogind`,
`dbus`, portals: yes. A compositor: pick your own (`sway`, `hyprland`,
`river`, `niri`, whatever nixpkgs has this week). A desktop environment:
no. GNUnix is a chassis, not a car. You want tiling and `foot`? Great.
You want a full DE somebody else maintains? Three lines of home-manager
away. Less for us to maintain is more Slack for everyone involved.

Every load-bearing decision has an ADR explaining why we made it and
what we rejected. When a future maintainer asks "why is `dbus` started
by `rc.dbus` and not by an `@reboot` cron entry?", the answer is a
one-page Markdown file, not folklore. X-Day is coming; you do not want
to be debugging a unit file when it gets here.

Think of GNUnix as Slackware that read the Nix paper and decided
reproducibility was, in fact, also Slack — or as NixOS that read the
SubGenius pamphlet and decided to relax. Either framing works. Both are
slightly unfair to the original.

## Layout

| Path | Purpose |
|---|---|
| `docs/` | Architecture, ADRs (`adrs/`), runbooks |
| `images/` | One subdir per Tart image, in build order |
| `bundles/` | Reusable Nix expressions |
| `tools/` | Pipeline programs (`build-all`, `promote`, `manifest.json`) |
| `scripts/` | Small auxiliary helpers |
| `tests/` | Boot smoke + Wayland session validation |
| `.github/` | CI workflows + Renovate config |

## Getting started

See `docs/architecture.md` for the two-layer model, `runbook.md` for the
build/test entry points, and `docs/adrs/` for the locked decisions
(init system, package layer, compositor, hardening, kernel architecture,
…).

For Claude Code sessions: read `CLAUDE.md` first.

## References

Projects, papers, and prophets that GNUnix steals from — with credit:

- [**Church of the SubGenius**](https://www.subgenius.com/) — the
  source of all Slack, and the reason Slackware is called Slackware.
  Praise "Bob."
- [**Slackware**](http://www.slackware.com/) — the oldest still-
  maintained Linux distribution. Direct ancestor of our base layer:
  `sysvinit`, BSD-style `/etc/rc.d/`, `chmod +x` to enable services,
  no policy daemons in the boot path.
- [**Linux From Scratch**](https://www.linuxfromscratch.org/) — the
  build recipe for the arm64 base image.
- [**GNU Project**](https://www.gnu.org/) — `coreutils`, glibc, GCC,
  bash, binutils. The entire userland-that-isn't-Nix.
- [**Nix & nixpkgs**](https://nixos.org/) — the package layer and
  the reason userland updates aren't terrifying.
- [**home-manager**](https://github.com/nix-community/home-manager) —
  per-user declarative config on top of Nix.
- [**Wayland**](https://wayland.freedesktop.org/) — the display
  server protocol we target. Compositors are user choice.
- [**sysvinit**](https://github.com/slicer69/sysvinit) — PID 1,
  unchanged in spirit since 1992, still boots faster than anything
  that replaced it.
- [**Tart**](https://tart.run/) — the macOS-native VM runner we ship
  images for.

---

<p align="center">
  <img src="assets/gnunix-fractal-banner.png" alt="GNUnix fractal banner" width="100%">
</p>
