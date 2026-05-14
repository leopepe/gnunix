<p align="center">
  <img src="assets/gnunix-logo-v1.png" alt="GNUnix logo" width="640">
</p>

# GNUnix

Custom Linux distribution for developer workstations on Apple Silicon.

The name is a pun: **GNU**'s-Not-Unix meets **Nix**. The base layer is built
almost entirely from the GNU toolchain (Linux From Scratch, arm64);
the userland is managed by Nix. Read either as GNUnix (GNU + Nix) or as
"GN[U] Unix" — both apply.

- **Base:** Linux From Scratch (arm64), Slackware-style `sysvinit` + BSD `/etc/rc.d/`.
- **Userland:** Nix (multi-user) + home-manager. All apps, the Wayland compositor, dev tools.
- **Delivery:** Tart VM images. Linear image lineage from `gnunix-builder` → `gnunix-base` → `gnunix-minimal` → `gnunix-desktop` → platform variants.

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

---

<p align="center">
  <img src="assets/gnunix-fractal-banner.png" alt="GNUnix fractal banner" width="100%">
</p>
