# Runbook: Building gnunix-desktop from gnunix-minimal

Phase 4 layers a Wayland graphical session on top of `gnunix-minimal-<ver>` and produces
`gnunix-desktop-<ver>`. The base image isn't rebuilt — Phase 4 reuses Phase 3's
output, exactly as Phase 3 reused Phase 2's.

Wall time: **~10–25 min** on M-series. Dominated by `nix-channel --update` and
the system-profile substitution from `cache.nixos.org`. No compilation.

## Prerequisites

- `gnunix-minimal-<ver>` exists in `tart list`. If not, run Phase 3 first
  (`tools/build-all.sh gnunix-minimal`).
- Host has `~/.ssh/id_ed25519.pub`. Phase 2 installed it as `root`'s
  `authorized_keys` inside the rootfs; Phase 3 carried it forward; Phase 4
  inherits it again.
- The build VM needs outbound network to `cache.nixos.org` and `channels.nixos.org`.
  Tart's default NAT works.

## One command

```sh
tools/build-all.sh gnunix-desktop
```

This calls `images/gnunix-desktop/build.sh`, which:

1. Verifies `gnunix-minimal-<ver>` exists.
2. `tart clone gnunix-minimal-<ver> → gnunix-desktop-build` (disposable working copy).
3. Boots `gnunix-desktop-build`, waits for `root@<ip>` over SSH.
4. Tars up `images/gnunix-desktop/etc/` + `install-wayland.sh`, scps the bundle
   into the VM.
5. Runs `install-wayland.sh` inside the VM:
   - Adds the pinned nixpkgs channel (`tools/manifest.json:.nix.channel`).
   - `nix-env -p /nix/var/nix/profiles/system -iA` for `dbus`, `elogind`,
     `greetd`, `tuigreet`, `sway`, `foot`, `swaybg`, `wayland-utils`,
     `xkeyboard_config`.
   - Creates the unprivileged login user `user` (UID 1000) with `wheel`,
     `video`, `input`, `render`, `audio`, `seat`, `nixbld`.
   - Installs `/etc/greetd/config.toml`, `/etc/sway/config`, `/etc/pam.d/greetd`,
     and the Phase 4 versions of `rc.dbus`, `rc.elogind`, `rc.greetd`, `rc.M`.
   - Drops `/usr/local/bin/start-wayland-session.sh` (greetd execs this).
   - Symlinks `pam_elogind.so` into `/lib/security/`.
   - `chmod +x` the rc.d scripts so `rc.M` runs them on next boot.
6. `sync; tart stop`.
7. `tart clone gnunix-desktop-build → gnunix-desktop-<ver>` (the deliverable).
8. Emits the raw disk image at `cache/artifacts/gnunix-desktop-disk-<ver>.img`
   plus a zstd-compressed sibling for distribution.

## Smoke test

```sh
tests/wayland-session.sh gnunix-desktop-0.1.0
```

Boots the image, ssh's in as root, validates:

- `dbus-daemon`, `elogind`, `greetd`, `tuigreet`, `sway`, `foot` all present
  under `/nix/var/nix/profiles/system/bin/` (and `elogind` under
  `libexec/elogind/`).
- `rc.dbus`, `rc.elogind`, `rc.greetd` are executable.
- `dbus-daemon`, `elogind`, `greetd` are running.
- `user` exists and is a member of `video`.
- WARN-only: `/dev/dri/card0` missing, `org.freedesktop.login1` D-Bus name
  not registered.

## What's deferred (ADR-009 "Out of scope")

This Phase 4 v1 lands the **components**. It doesn't yet:

- Boot all the way to a *visible* sway frame from CI (needs a display-test
  rig with `wlr-randr` + screenshot diff, tracked in `docs/TODO.md`).
- Ship `xdg-desktop-portal` (needs a backend choice; deferred to Phase 4.1).
- Run home-manager (ADR-004 says home-manager owns user config; bootstrapping
  it is its own runbook — next).

## Logging into the running VM (Wayland)

```sh
tart run gnunix-desktop-0.1.0           # WITH graphics — Tart opens a window
```

You should land at greetd's tuigreet prompt on VT1. Username: `user`. Password
is blank by default (PAM stack uses `pam_permit.so`; see security notes below).
On Enter, tuigreet execs `/usr/local/bin/start-wayland-session.sh`, which
launches sway on `virtio-gpu`.

## Logging in over SSH (no graphics)

```sh
tart run --no-graphics gnunix-desktop-0.1.0 &
. scripts/tart-helpers.sh
IP=$(tart_ip gnunix-desktop-0.1.0)
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$IP
```

Inside the VM:

```sh
loginctl list-sessions                # elogind sessions
pidof greetd; pidof sway              # supervisor + session
dbus-send --system --print-reply --dest=org.freedesktop.DBus \
  /org/freedesktop/DBus org.freedesktop.DBus.ListNames | grep login1
```

## Security notes

The default greetd PAM stack is `pam_permit.so` for `auth` so the smoke test
can log in unattended. **For shipping images this must change** — either set
a password (`passwd user`) and switch `auth sufficient pam_permit.so` to
`auth required pam_unix.so`, or wire up `pam_ssh_agent_auth.so` for key-only
login. Tracked in `docs/TODO.md` under "System configuration hardening".

## Iterating

`build.sh` re-clones `gnunix-minimal-<ver> → gnunix-desktop-build` every time, so
iterations are stateless — same pattern as Phase 3.

If you want to debug the in-progress build VM (e.g., `nix-env -iA` exploded),
don't re-run the orchestrator: ssh into `gnunix-desktop-build` while it's still
running, fix the install state, then manually `sync` + `tart stop` and
`tart clone gnunix-desktop-build gnunix-desktop-0.1.0`.

## Consumers of the produced image

Same as Phase 3: `cache/artifacts/gnunix-desktop-disk-0.1.0.img` is a generic
GPT/UEFI/ext4 disk image. Tart is one consumer; QEMU/KVM, libvirt, UTM,
Proxmox, and arm64 bare metal with UEFI also boot it directly. See
[`build-minimal.md` § Consumers](build-minimal.md#consumers-of-the-produced-image).
