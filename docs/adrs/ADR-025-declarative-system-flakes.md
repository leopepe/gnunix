# ADR-025: Declarative system configuration — the flake is the source of truth for system package sets

**Status:** Accepted
**Date:** 2026-09-13
**Supersedes:** [ADR-004](ADR-004-config-style.md), [ADR-024](ADR-024-declarative-nix-profiles.md)
**Amends:** [ADR-009](ADR-009-wayland-stack.md), [ADR-017](ADR-017-live-iso-architecture.md) (package-set sourcing only)

Architecture impact: see architecture.md §Two-layer model, §How the system
profile is built, §Locked decisions, §Key invariants.

## Context

ADR-004 settled configuration style in May: home-manager for the per-user
layer, hand-curated files under `images/lfs-core/etc/` for the system files
that cannot live in Nix, and no NixOS modules. It closed with two lines under
*Out of scope*:

```text
- NixOS modules: violates the architectural split.
- Flakes-as-system-config: same reason; flakes for *bundles* are fine.
```

"Same reason" is the error this ADR corrects. Everything else in ADR-004 was
right, including the architectural split it was defending.

A NixOS module system owns init, services, users, mounts and kernel
parameters. Importing it would replace sysvinit and BSD `/etc/rc.d/`
(ADR-001), replace the seat wiring (ADR-002), and put system state back inside
Nix — which is precisely the split ADR-004 exists to protect. That ban is
correct and stays.

A flake that evaluates to a `pkgs.buildEnv` is a different object. Its entire
output is a store path containing `bin/`, `lib/`, `share/` — a symlink tree.
It declares no service, starts no daemon, owns no `/etc`, and has no opinion
about PID 1. Rejecting it "for the same reason" rejected a *declaration
format* on grounds that only apply to a *system-ownership model*.

The consequence was not neutral. With NixOS modules banned and flakes banned
alongside them, the only permitted way to put packages into a GNUnix image was
`nix-env -iA` against a `nix-channel` subscription — an imperative command
against a moving branch. That is the least reproducible option Nix offers, and
the project arrived at it by elimination rather than by choice.

ADR-024 (Proposed, never merged) reached the right mechanism but framed it as
an amendment to ADR-004 whose objection "does not reach a `buildEnv`". That
framing understates it. The objection was misapplied, the resulting
prohibition was load-bearing, and the project needs a decision that states
plainly which approach is authoritative rather than one that carves an
exception out of a rule it leaves standing. This ADR supersedes both: ADR-004
because its *Out of scope* section is wrong in a way that changed the
architecture, and ADR-024 because a superseding decision should be readable in
one file. Per the ADR-023 precedent, everything from ADR-004 that survives
— home-manager for the per-user layer, hand-curated system files, the
NixOS-module ban — is absorbed here, so no authority is orphaned.

### The evidence is practical, not theoretical

Every item below was observed in CI, not predicted.

**1. The channel makes the distribution non-reproducible by construction.**
`images/gnunix-desktop/build.sh:123` and `images/installer/build.sh:146` both
run:

```sh
nix-channel --add "https://nixos.org/channels/nixos-25.11" nixpkgs
nix-channel --update
```

`nixos-25.11` is a branch, not a revision. The same git commit built a week
apart resolves to two different nixpkgs trees and produces two different
images. `tools/manifest.json` pins every LFS component to a sha256 (ADR-011,
ADR-023) and then hands the whole Nix layer to something that moves
underneath it; its `.nix.nixpkgs_rev_pin` field exists and is the empty
string. A distribution that ships tagged releases (ADR-018, ADR-023) has to be
able to rebuild what a user is reporting a bug against. Against a channel it
cannot: `0.1.1` names an LFS base exactly and a userland approximately.

**2. The package set was undeclared.** No file stated what `gnunix-desktop`
contains. The answer was the union of the `-iA` arguments spread across
`images/gnunix-desktop/build.sh`, `images/gnunix-desktop/install-gnunix-desktop.sh`,
`images/installer/build.sh` and `images/installer/install-installer.sh`,
several of them inside quoted heredocs — shell text inside shell text. Because
nothing stated the intent, nothing could check the result: the desktop and
installer sets drifted apart silently, and five tools the installed system
needs (`sgdisk`, `partprobe`, `rsync`, `mkfs.vfat`, `whiptail`) were
discovered missing at build time, one error message at a time.

**3. Running Nix inside a chroot is a failure class, and it was fixed one
symptom at a time across four PRs in a single day:**

| Symptom | Cause | Fixed in |
|---|---|---|
| `cannot pivot old root directory onto '…/real-root': Invalid argument` | the build sandbox sets each derivation up with `pivot_root(2)`, which returns `EINVAL` inside a chroot | [#147](https://github.com/leopepe/gnunix/pull/147), [#152](https://github.com/leopepe/gnunix/pull/152) |
| `cannot connect to socket at '/nix/var/nix/daemon-socket/socket'` | `NIX_REMOTE=daemon` is inherited, but no `nix-daemon` runs inside the chroot | [#150](https://github.com/leopepe/gnunix/pull/150) |
| `attribute 'nixpkgs' in selection path 'nixpkgs.xorriso' not found` | `-iA nixpkgs.…` resolves against a channel the image never subscribed to | [#150](https://github.com/leopepe/gnunix/pull/150) |
| `read_symlink: Invalid argument [/nix/var/nix/profiles/system]` | the profile path was pre-created with `mkdir -p`; `nix-env -p` needs to make it a symlink | [#153](https://github.com/leopepe/gnunix/pull/153) |

Each fix was correct and none addressed the cause: a chroot is not a machine.
It has no daemon, no channel subscription, no working `pivot_root`, and no
`/proc` unless one is bound in. `ubuntu-22.04-arm` (ADR-021) is a native
aarch64 Linux host that has all four. The packages are built for
`aarch64-linux` either way — nothing about the artifact requires the chroot,
only the habit of installing from inside it does.

**4. `nix-env -iA` is additive and unverifiable.** It computes a new
user-environment from the union of what is already in the profile plus what
was just named, so the result depends on the order commands ran and on what a
previous run happened to leave behind. There is no state in which the profile
can be compared against a declaration, because there is no declaration.

## Decision

**GNUnix's system-wide package sets are declared in the repository's flake.
The flake plus `flake.lock` is the source of truth for what a released image
contains. `nix-env -iA` and `nix-channel` are not used to establish system
state, in any image, at any stage of the build.**

This is a pivot to a declarative system, not a workaround for the chroot
failures above. The chroot failures are what made the imperative model's cost
visible; the reason to leave it is that a distribution's contents should be
readable from the repository and reproducible from a commit.

### 1. Two layers, governed separately

| Layer | Declared in | Installed by | Governed by |
|---|---|---|---|
| **System** — what the release ships, shared by every user | `flake.nix` + `nix/*.nix`, pinned by `flake.lock` | `nix-env --profile /nix/var/nix/profiles/system --set` on the runner-built closure | **this ADR** |
| **Per user** — the user's own apps and dotfiles | the user's `home.nix`, composed from `bundles/*.nix` | `home-manager switch`, or `nix profile` / `nix-env` into `~/.nix-profile` | **this ADR, §User customization** (absorbed unchanged from ADR-004) |

System files that genuinely cannot live in Nix — `inittab`, `rc.d`, `fstab`,
kernel cmdline — remain hand-curated under the image trees in `images/`
(absorbed from ADR-004; the path has since been renamed `lfs-core` →
`gnunix-base` per ADR-013).

### 2. The flake is the declaration

`flake.nix` at the repository root exports one `pkgs.buildEnv` per system
package set, for `aarch64-linux`:

| Output | Contents | Consumer |
|---|---|---|
| `packages.aarch64-linux.desktopProfile` | `nix/desktop.nix` — dbus, elogind, greetd, tuigreet, Hyprland, xdg-desktop-portal-hyprland, hyprpaper, foot, wayland-utils, xkeyboard_config, procps, kmod, mesa, waybar | `gnunix-desktop` system profile |
| `packages.aarch64-linux.installerProfile` | `nix/installer.nix` — the live installer's runtime (whiptail, sgdisk, partprobe, rsync, mkfs.vfat) | `gnunix-installer` system profile |
| `packages.aarch64-linux.installerBuildTools` | `nix/installer-build.nix` — the ISO assembly toolchain (xorriso, squashfsTools, cpio, mtools, dosfstools, busybox, grub2) | build host only; never shipped |
| `packages.aarch64-linux.minimalProfile` | `nix/minimal.nix` — `gnunix-minimal` is the LFS base plus Nix itself (ADR-003) | `gnunix-minimal` |

Each is built with `pathsToLink = [ "/bin" "/lib" "/share" "/etc" "/libexec" ]`,
so one store path carries everything the existing `PATH`, `LD_LIBRARY_PATH`,
`LIBGL_DRIVERS_PATH` and `__EGL_VENDOR_LIBRARY_DIRS` exports already point at.

The runtime/build-tool distinction becomes structural rather than a comment:
`installerBuildTools` is a separate output, built on the runner and never
copied into an image. This replaces the ADR-017 step of `nix-env`-ing the ISO
toolchain into a build VM's system profile; the ISO recipe itself (squashfs +
overlayfs + hybrid EFI) is unchanged. Likewise the ADR-009 Wayland substrate
is unchanged — only where its package list is written changes, from `-iA`
arguments to `nix/desktop.nix`.

### 3. Build on the runner, swap the profile in the image

```sh
OUT=$(nix build --no-link --print-out-paths .#desktopProfile)
nix copy --no-check-sigs --to "$MNT" "$OUT"
chroot "$MNT" nix-env --profile /nix/var/nix/profiles/system --set "$OUT"
```

`nix copy --to <dir>` writes a local store rooted at that directory, which is
the mounted image. The only command that runs inside the chroot is
`nix-env --set`: it registers a generation and relinks a symlink. It builds
nothing, so it needs no sandbox, no daemon and no channel — the four failures
above have no surface left to appear on.

`--set` points the profile at exactly that derivation in one `rename(2)`
rather than computing a union. A build either produces the declared profile or
leaves the previous one in place; there is no half-installed state.
Generations are still recorded under `/nix/var/nix/profiles/`, so
`--rollback` and `--list-generations` work as they always have.

### 4. Pinning

`flake.lock` pins nixpkgs to an exact revision. The flake *input* tracks the
branch named by `tools/manifest.json` `.nix.channel` (`nixos-25.11`); the lock
file fixes the revision that branch resolved to. One commit of this repository
therefore names one nixpkgs tree, permanently — which is what
`.nix.nixpkgs_rev_pin` was reserving space for and never delivered.
`flake.lock` joins `tools/manifest.json` and `bundles/*.nix` as a Renovate
target under the single-pin convention of
[ADR-023](ADR-023-cve-hotfix-batch-and-ci-rebuild.md). A nixpkgs bump becomes
a reviewable diff of one hash with a CI run attached — which the channel made
impossible, since there was no artifact to bump and no diff to review.

### 5. The boundary this decision does not cross

The flake is a package-set declaration. It is not, and must not become, a
route to NixOS:

- No `configuration.nix`, no `nixosConfigurations`, no NixOS module import
  anywhere in `flake.nix` or `nix/`.
- No systemd unit and no service definition. Boot stays sysvinit + BSD
  `/etc/rc.d/` (**ADR-001, unchanged**); seat management stays elogind
  (**ADR-002, unchanged**), started from `rc.elogind`.
- Nothing in the flake creates users, mounts filesystems, or writes `/etc`
  outside the store path it produces.

A pull request that adds a `nixosConfigurations` output, or that has the flake
emit an init unit, contradicts this ADR and ADR-001 both. It is the one change
to `flake.nix` that requires a new ADR rather than a review.

**ADR-003 is unchanged.** `/nix` stays root-owned, `nixbld1..32` stay,
`sandbox = true` stays in the image's own `/etc/nix/nix.conf`, and
`rc.nix-daemon` still supervises the daemon on the running system. What ends
is the attempt to *use* that model during image assembly: build-time work is
root on the runner against the runner's store, and the image's Nix
configuration is never overridden at build time. The `NIX_CONFIG=sandbox=false`
workaround from #152 and the `--option sandbox false` flags from #147 are no
longer needed on the desktop and installer paths.

## Consequences

### System-wide, shared by every user

The declared set installs into `/nix/var/nix/profiles/system` — one profile,
one store closure, root-owned under ADR-003, readable by every account. There
is no per-user copy of a shipped package and no per-user step to make a
shipped package available. `rc.dbus`, `rc.elogind` and `rc.greetd` resolve
their binaries under that one path, so the system services and the users' own
sessions run the same builds.

### Boot persistence: real for storage, incomplete for `PATH`

The storage half holds. `/nix/var/nix/profiles/system` is a symlink on the
ext4 root filesystem (`LABEL=lfs-root` in
`images/gnunix-base/etc/fstab.template`) pointing into `/nix/store` on that
same filesystem. Neither is a tmpfs — the template mounts tmpfs only on
`/run`, `/tmp` and `/dev/shm`. A profile written by `--set` is still there
after a reboot, along with its previous generations.

The `PATH` half does not, and this ADR records it as a known gap rather than
claiming otherwise:

- `images/gnunix-base/etc/profile` sets
  `PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin` and then sources
  `/etc/profile.d/nix-daemon.sh`.
- That file (written by `images/gnunix-minimal/install-gnunix-minimal.sh:105-112`)
  sources only the *default* profile's
  `/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh` and exports
  `NIX_SSL_CERT_FILE`. It does **not** add
  `/nix/var/nix/profiles/system/bin` to `PATH`.
- The system profile reaches a process today only through explicit exports in
  session wrappers — `/usr/local/bin/start-wayland-session.sh` (written by
  `images/gnunix-desktop/build.sh:288`) and the installer compositor profiles
  under `images/installer/installer/profiles/desktop-*.sh` — and through
  absolute paths in `images/gnunix-desktop/etc/rc.d/rc.{dbus,elogind,greetd}`,
  `etc/greetd/config.toml`, `etc/pam.d/greetd`, and
  `images/gnunix-desktop/etc/hypr/hyprland.conf:20,75`.

So a graphical session sees the system profile, and a plain tty or SSH login
does not. Declaring a package in `nix/desktop.nix` today guarantees it is on
disk and reachable by absolute path; it does not guarantee a logged-in user
can type its name.

**Named remedy:** a second drop-in, `/etc/profile.d/nix-system-profile.sh`,
written by the same installer step that writes `nix-daemon.sh`, exporting
`PATH`, `MANPATH`, `XDG_DATA_DIRS` and `LD_LIBRARY_PATH` entries for
`/nix/var/nix/profiles/system`. It is deliberately not bundled into this ADR's
first implementation, because it changes what every login shell resolves and
deserves its own change with its own smoke test. Until it lands, the invariant
to state honestly is: *the system profile is boot-persistent; its presence on
an interactive `PATH` is not yet wired.*

### User customization stays the user's business

The flake governs what the release ships. It never reaches into `$HOME` and it
never runs on a user's machine on their behalf. After install:

- `~/.nix-profile` works. `nix profile` and `nix-env` work per user against the
  daemon (ADR-003).
- home-manager remains the supported route for per-user declarative
  configuration, with each user's `home.nix` composed from `bundles/*.nix`.
  This is ADR-004's decision, absorbed here unchanged; superseding ADR-004
  changes the system layer only.
- A user customizing their machine does not edit this repository.

One ordering consequence follows from the remedy above and should be settled
when it is implemented: in a **login shell**, the user's own profile must take
precedence over the system profile (`~/.nix-profile/bin` before
`/nix/var/nix/profiles/system/bin`), so a user who installs their own version
of a shipped tool gets theirs. In a **session wrapper**, the order is
deliberately the opposite — the wrapper's job is to launch the compositor the
release shipped, so it puts the system profile first, as
`start-wayland-session.sh` already does. Two different orders for two
different jobs; both belong in the drop-in's design, not left to chance.

Installer compositor profiles under `images/installer/installer/profiles/`
still install at install time, on the target machine, against the running
system's daemon (ADR-015, ADR-019, ADR-022). That is a legitimate imperative
use of Nix — it happens on a booted machine, not in a chroot on a build host
— and this ADR does not change it.

### Flakes are still an experimental Nix feature

Nix marks `nix-command` and `flakes` experimental and has for years. Two
reasons that is acceptable here rather than merely tolerated:

1. **The image already enables them.**
   `images/gnunix-minimal/install-gnunix-minimal.sh:99` writes
   `extra-experimental-features = nix-command flakes` into `/etc/nix/nix.conf`
   (verified on this commit). This ADR adds no new experimental surface to the
   shipped system; it starts using a feature the distribution already turned
   on.
2. **The exposure is bounded.** Flake evaluation happens on the build runner.
   What lands in the image is a store closure and a profile symlink —
   artifacts of the stable, pre-flake Nix data model. If the flake schema
   changed incompatibly tomorrow, the repair would be confined to `flake.nix`
   and `nix/*.nix`; no shipped image would need rebuilding to stay bootable.

The alternative that avoids the experimental flag — `npins`, `niv`, or a
hand-written `nixpkgs.json` plus `fetchTarball` — buys stability of interface
at the cost of a bespoke pinning mechanism that Renovate does not understand
and that no contributor arrives already knowing. Flakes are the pinning
mechanism the ecosystem converged on.

### Build surface

- Adds: `flake.nix`, `flake.lock`, `nix/profile.nix`, `nix/desktop.nix`,
  `nix/installer.nix`, `nix/installer-build.nix`, `nix/minimal.nix`.
- Removes from `images/gnunix-desktop/build.sh` and `images/installer/build.sh`:
  the `nix-channel --add/--update` pair, every chroot-side `nix-env -iA`, the
  `NIX_CONFIG` / `--option sandbox false` workarounds, and the `/proc`,
  `/dev/null` and pty binds that existed only so `nix-env` could run in there.
- CI (`.github/workflows/build.yml`) needs Nix on the runner with
  `nix-command flakes` enabled, and a flake-aware cache key.
- Forks get a rebuild of the exact userland from the exact commit — the fork
  story ADR-021 argues for and the channel silently broke.

### Documentation

ADR-004 and ADR-024 are marked `Superseded by ADR-025` and stay in
`docs/adrs/` per repo convention (the ADR-008 / ADR-016 precedent). ADR-009's
and ADR-017's amendment notes name this ADR directly, so no note points at a
superseded decision.

## Out of scope

- **NixOS modules.** Still banned — now for the reason that actually applies.
  A module set owns init, services, users and mounts, which contradicts
  ADR-001 and ADR-002 and dissolves the static-base / dynamic-userland split.
  A flake exporting `buildEnv` derivations owns none of those things and is
  not a step toward `nixosConfigurations`. The two were conflated once; they
  are not conflated again.
- **x86_64.** The flake exports `aarch64-linux` only. A second system is
  ADR-010 Phase 5 work and gets written into `flake.nix` when that phase
  lands, not abstracted for in advance.
- **Per-user declarative configuration.** home-manager and `~/.nix-profile`
  keep working exactly as ADR-004 defined them and as restated above. Nothing
  here changes how users manage their own environments, and the repository's
  flake is never the mechanism for doing so.
- **Declaring the LFS base in Nix.** The base is built from source per ADR-007
  and pinned in `tools/manifest.json` per ADR-011 / ADR-023. Nothing here
  touches it.
- **Binary cache / substituter changes.** The build keeps substituting from
  `cache.nixos.org`. Whether GNUnix publishes its own cache is separate work.
- **The `/etc/profile.d` drop-in itself.** Named above as the remedy for the
  `PATH` gap, scoped as its own change with its own test.

## Open questions

1. **`PATH` ordering in the drop-in.** Settle user-profile-before-system in
   login shells against system-profile-first in session wrappers, and confirm
   that neither shadows an LFS base tool something in `rc.d` depends on.
2. **Renovate's nix manager.** `.github/renovate.json5` still carries the
   comment "Don't update lock files (we have none yet; Phase 3 may add
   flake.lock)". Renovate's `nix` manager is enabled by default and should
   pick `flake.lock` up, but this has not been seen on a real PR. Verify on
   the first nixpkgs bump after the flake lands.
3. **Does `minimalProfile` earn its existence?** It may be an empty `buildEnv`
   today. If `gnunix-minimal` never needs a system profile, drop the output
   rather than ship it empty.
4. **Closure size in the image.** `nix copy` moves the full closure. No
   measurement exists of whether the image grows or shrinks relative to the
   channel-based builds. Measure once a green run exists.
