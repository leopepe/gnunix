# `gnunix-minimal`

`gnunix-base` + the **multi-user Nix daemon**. The dynamic-userland
half of the project sandwich joins the static base here, in a single
image that is also the **CI release-dependency anchor** (ADR-018):
downstream layers fetch this image rather than rebuild it.

## Objective

Give every downstream image (`gnunix-desktop`, `gnunix-installer`,
`variants/<platform>`) the smallest possible "Nix is here, daemon is
supervised, nixpkgs is reachable" foundation, so layering compositors
/ portals / apps becomes a one-line `nix-env -iA …`.

It's also a **first-class product** in its own right: a headless
GNUnix dev box with `sshd` + Nix and nothing else, suitable for
build farms, CI workers, or a no-GUI workstation.

## Summary of features

- **Multi-user Nix daemon**, installed from the upstream binary
  tarball pinned in `tools/manifest.json:nix.binary_url` (sha256-
  verified). No NixOS modules, no flakes-as-system — plain
  `/nix/var/nix/profiles/` (ADR-003, ADR-004).
- **`rc.nix-daemon`** supervises `nix-daemon` via `start-stop-daemon`
  with `--background --make-pidfile`. No systemd, no `runit`/`s6`
  shim. Same Slackware-style toggle (`chmod +x`/`-x`) as every other
  service.
- **`nixbld` build users** created at install time (32 of them per
  upstream Nix convention), in the `nixbld` group.
- **Channels pinned**: `nixos-25.11` by default; bumps go through
  Renovate (ADR-008).
- **No graphical session** — `getty` on tty1 stays enabled, `greetd`
  stays disabled. This is intentional; the desktop layer is a
  separate image.
- Inherits everything from `gnunix-base` (sysvinit, hardened
  toolchain, module-first kernel, GRUB EFI).

## Layout

```
build.sh                    host orchestrator: clones the previous
                            gnunix-base-<ver> Tart VM, scp's the Nix
                            tarball + installer in, runs the installer
                            inside the VM, snapshots the result as
                            gnunix-minimal-<ver>.
install-gnunix-minimal.sh   in-VM provisioner: unpacks the Nix tarball,
                            creates nixbld users, writes rc.nix-daemon,
                            enables it.
```

## Build

```sh
# Requires gnunix-base-<ver> on disk (build it or fetch with
# tools/fetch-image.sh):
tools/build-all.sh gnunix-minimal
# → cache/artifacts/gnunix-minimal-aarch64-<ver>.img(.zst)
```

Build cost is small (~10 min on Apple Silicon) but still runs
locally — the upstream Nix binary tarball is the long lever, not
this script.

## Release-dependency anchor (ADR-018)

This is the image CI fetches via `tools/fetch-image.sh` to layer
`gnunix-desktop` and `gnunix-installer` on top of, instead of
rebuilding `gnunix-base` + the Nix daemon from scratch on every PR.
Two reasons (full rationale in ADR-018 § "Anchor"):

- The Nix daemon install is the slowest *cacheable* step in the
  chain after the base build. Caching it once at the
  `gnunix-minimal-<ver>` tag is the single biggest CI win available
  under ADR-021's hosted-runner constraint.
- A user who wants a headless dev box can download
  `gnunix-minimal-<arch>-<ver>.img.zst` directly and stop there —
  it's the smallest published image that actually does useful work.

## Validate

```sh
tests/minimal/minimal-smoke.sh gnunix-minimal-<ver>
```

Asserts: boot, DHCP, TTY login, `nix-daemon` running and answering,
`nixbld` users present, channel reachable. Mandatory gate for any
change under `images/gnunix-minimal/`.

## See also

- [ADR-003](../../docs/adrs/ADR-003-nix-multi-user.md) — multi-user Nix daemon
- [ADR-004](../../docs/adrs/ADR-004-config-style.md) — plain Nix profiles + home-manager
- [ADR-018](../../docs/adrs/ADR-018-artifact-taxonomy.md) — release anchor + artifact taxonomy
- [ADR-019](../../docs/adrs/ADR-019-image-lineage-and-installer-pivot.md) — image lineage
