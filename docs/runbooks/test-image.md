# Runbook: Testing an gnunix-base image

After `tools/build-all.sh gnunix-base` (or `tools/phase2.sh`) produces `gnunix-base-<version>`, validate it.

## Smoke test (automated)

```sh
tests/boot-smoke.sh gnunix-base-0.1.0
```

Returns 0 on pass; non-zero with a one-line failure reason otherwise. Driven by `scripts/validate-boot.sh`.

### Pass criteria

- VM acquires a DHCP lease within ~30s. `tart_ip` (with ARP fallback) returns its address.
- `sshd` accepts the host's `~/.ssh/id_ed25519.pub` as root; `pidof sshd` returns a PID.
- `ip route get 1.1.1.1` resolves a default route.

### Warnings (not failures)

These are emitted as `WARN:` lines and do not block the milestone — both packages are deferred to a later phase (they need a Python+meson bootstrap that isn't wired into stage 2 yet):

- `dbus-daemon` not running.
- `elogind` not running.

When dbus + elogind come back (Phase 3 or earlier), flip those checks back to hard failures in `scripts/validate-boot.sh`.

## Manual interactive test

```sh
tart run gnunix-base-0.1.0                            # GUI window with console
tart run --no-graphics --serial gnunix-base-0.1.0     # capture console to a pty (printed to stdout)
```

SSH in (the host pubkey was installed at build time):

```sh
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    root@$(. scripts/tart-helpers.sh && tart_ip gnunix-base-0.1.0)
```

Inside the VM, sanity checks:

```sh
uname -a                        # Linux gnunix-base 6.12.20 #1 SMP PREEMPT ... aarch64
ip a show eth0                  # virtio-net up with DHCP lease (192.168.64.x/24)
ip route                        # default route via 192.168.64.1
pidof sshd                      # running
ls /etc/rc.d/                   # rc.S rc.M rc.K rc.6 rc.local rc.network rc.sshd rc.nix-daemon ...
ls -l /etc/rc.d/rc.*            # executable flag = enabled (Slackware convention, ADR-001)
                                # rc.dbus and rc.elogind are -rw-r--r-- on purpose (deferred)
cat /var/log/dhcpcd.log         # last DHCP exchange
ls /nix 2>/dev/null && echo IN_PHASE_3 || echo PHASE_2_ONLY   # /nix shouldn't exist yet
```

## Iterating

If a service fails to start:

1. Boot single-user via the GRUB menu's `gnunix-base (single-user)` entry, or the `gnunix-base (emergency shell)` entry which drops straight to bash via `init=/bin/bash` (handy when `/sbin/init` itself misbehaves).
2. Inspect `/etc/rc.d/rc.<service>` — simple shell scripts.
3. Fix in the repo (`images/gnunix-base/etc/rc.d/`), re-run `REUSE_BUILDER=1 tools/build-all.sh gnunix-base`. Only `mkimage` + `tart-import` re-run if you're past the build stages.

If the kernel won't boot:

1. Run `tart run --no-graphics --serial gnunix-base-0.1.0` and read the pty path it prints. `cat $PTY > boot.log &` to capture the boot console.
2. Adjust `images/gnunix-base/kernel.config` (most commonly a missing `CONFIG_VIRTIO_*`) or `images/gnunix-base/grub.cfg` (root parameter, console order).
3. Re-run `REUSE_BUILDER=1 tools/build-all.sh gnunix-base --rebuild=finalize` to rebuild only the kernel + GRUB image without redoing the multi-hour stages.

If DHCP succeeds but `tart ip` returns "no IP address found":

That's the Apple-bootpd-vs-dhcpcd mismatch (see `docs/runbooks/build.md` item 14). `scripts/tart-helpers.sh:tart_ip` falls back to ARP lookup by the VM's MAC. If even that's empty, the VM probably hasn't completed boot — give it another ~30s.

If SSH connects but auth fails:

The host SSH key install happens in `tools/build-all.sh` right after the build stage. If you ran `mkimage` standalone or the key file was missing at build time, ssh-copy-id manually:

```sh
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@$(. scripts/tart-helpers.sh && tart_ip gnunix-base-0.1.0)
```
