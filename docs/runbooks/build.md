# Runbook: Building gnunix-base from scratch

End-to-end procedure to produce the Phase 2 milestone — a bootable `gnunix-base` Tart image. Expect **~6–10 hours of wall time on an M-series Mac**, mostly compute-bound (cross-toolchain, gcc-pass2, kernel, full chroot rebuild of ~30 packages). Compute scales linearly with cores; the script uses all available via `$(nproc)`.

## Prerequisites on the macOS host

```sh
brew install cirruslabs/cli/tart jq rsync
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519   # only if you don't already have a key
```

The SSH key is required: `bootstrap-builder.sh` installs it into `admin@gnunix-builder` (so subsequent SSH/rsync to the builder is passwordless), and `build-all.sh` installs it into `/root/.ssh/authorized_keys` in the built image (so the smoke test can ssh in as root).

## Fast path — one command

```sh
tools/phase2.sh           # gated, prompts before each stage
# or
AUTO=1 tools/phase2.sh    # unattended (CI, overnight runs)
```

This runs four stages in order, each idempotent and individually re-runnable:

1. **Stage 0 — pre-fetch sources to `cache/sources/`** (`tools/fetch-sources.sh`). 5–15 min over your host's network. Mirror fallback handles `ftp.gnu.org` flakiness.
2. **Stage 1 — bootstrap `gnunix-builder:base`** (`tools/bootstrap-builder.sh`). 10–25 min, one-time. Pulls cirruslabs Ubuntu, runs `provision.sh`, installs your SSH key, snapshots.
3. **Stage 2 — build the gnunix-base image** (`tools/build-all.sh gnunix-base`). The long stage. Drives every LFS book chapter from inside `gnunix-builder-build`, then packages the result with `mkimage.sh` and imports it as `gnunix-base-<version>` via `tart create --linux` + disk swap (`tart-import.sh`).
4. **Stage 3 — smoke test** (`tests/boot-smoke.sh gnunix-base-0.1.0`). Boots the new VM, validates SSH + default route, warns (but doesn't fail) on deferred services.

On success: `tart list` shows `gnunix-base-0.1.0`, and `tart run gnunix-base-0.1.0` boots a working LFS arm64 system.

## What stage 2 does, step by step

`build-all.sh` orchestrates this sequence inside `gnunix-builder-build`:

| Stage | Script | Output | Wall time |
|---|---|---|---|
| fetch | `tools/fetch-sources.sh` (in chroot) | `/mnt/lfs/sources/*.tar.*` (or no-op if host already pre-fetched) | 0–15 min |
| cross | `images/gnunix-base/stages/01-cross-toolchain.sh` | `$LFS/tools/bin/aarch64-lfs-linux-gnu-*` (binutils-pass1, gcc-pass1, headers, glibc, libstdc++) + the GCC limits.h chain fix | 1.5–3 h |
| temp-tools | `images/gnunix-base/stages/02-temp-tools.sh` | minimal userspace in `$LFS/usr/` + `binutils-pass2` + `gcc-pass2` (native-named `cc`/`ld`/`ar`/...) | 1.5–2.5 h |
| chroot | `images/gnunix-base/stages/03-chroot.sh` → `03b-chroot-inner.sh` | full LFS chapter 7 + chapter 8: bison, flex, gperf, pkgconf, perl, python, libxcrypt, shadow, util-linux, base packages, openssl, sysvinit, eudev, openssh, grub | 2–4 h |
| finalize | `images/gnunix-base/stages/04-finalize.sh` | rc.d installed, kernel 6.12.20 built, GRUB EFI, locale, root pwd locked, strip | 30–60 min |
| mkimage | `images/gnunix-base/packaging/mkimage.sh` (in VM) | GPT disk image at `/tmp/gnunix-base-disk.img` | 3–5 min |
| import | `images/gnunix-base/packaging/tart-import.sh` (on host) | Tart VM `gnunix-base-<version>` | <30 s |

Per-package markers under `/var/lib/lfs-pkgs/<name>.done` inside the rootfs make the **chroot stage** resumable — a retry after fixing one package only re-runs that package. Per-stage markers under `/mnt/lfs/.lfs-stages/<stage>.done` make the **whole pipeline** resumable.

## Resuming a failed build

```sh
# Fresh start: deletes gnunix-builder-build, re-clones from :base.
tools/build-all.sh gnunix-base

# Resume: keeps gnunix-builder-build and its stage/package markers.
# Use this when you've fixed a single thing and want to continue from
# where the build stopped, not redo the cross-toolchain (~3h).
REUSE_BUILDER=1 tools/build-all.sh gnunix-base
```

Force-rebuild a single stage:

```sh
scripts/enter-vm.sh gnunix-builder-build "sudo REBUILD=temp-tools \
  bash /home/admin/gnunix/images/gnunix-base/build.sh --rebuild=temp-tools"
```

To force-rebuild a single chroot-stage package, delete its marker from inside the VM:

```sh
scripts/enter-vm.sh gnunix-builder-build "sudo rm /mnt/lfs/var/lib/lfs-pkgs/<pkg>.done"
REUSE_BUILDER=1 tools/build-all.sh gnunix-base
```

## Acceptance criteria (Phase 2 milestone)

`tests/boot-smoke.sh gnunix-base-0.1.0` PASSes when:

- VM gets a DHCP lease on virtio-net within ~30s.
- `sshd` accepts the host's ed25519 key as root, with `pidof sshd` returning a PID.
- `ip route get 1.1.1.1` resolves a default route.

It WARNs (but doesn't fail) when `dbus-daemon` or `elogind` isn't running — both are deferred to a later phase (they need Python+meson bootstrap we haven't wired into stage 2 yet; the Nix layer or a future stage will bring them back).

## What's in the manifest

`tools/manifest.json` pins every package with sha256. The 36 base + 4 toolchain + 4 init/session + 1 bootloader = **45 source tarballs**. Highlights:

- **Toolchain**: binutils 2.43.1, gcc 14.2.0 (with gmp 6.3.0, mpfr 4.2.1, mpc 1.3.1, isl 0.27), linux 6.12.20, glibc 2.40.
- **Chroot temp-tools**: m4 1.4.20 (1.4.19 has a glibc-2.40 gnulib bug), perl 5.38.2 (5.40 has a locale.c codegen bug), python 3.12.5, bison 3.8.2, flex 2.6.4, gperf 3.1, pkgconf 2.3.0, libxcrypt 4.4.36 (provides `crypt()` which glibc-2.40 dropped).
- **Base**: bash 5.2.32, coreutils 9.5, util-linux 2.40.2, shadow 4.16.0 (`--without-libbsd`), openssh 9.9p1, openssl 3.3.2, sysvinit 3.10, eudev 3.2.14, grub 2.12.
- **Deferred**: dbus, elogind, iputils — meson-based; need Python+meson which we haven't bootstrapped. iputils gives us `ping`; the others are session/IPC. The image boots and runs SSH/network without them.

## Why the build looks the way it does (key non-obvious choices)

Each of these took an iteration to find; they're documented in the code where they live so a clean rebuild gets the fix automatically.

1. **`01-cross-toolchain.sh:fix_gcc_limits_chain()`** — gcc-pass1 is built `--without-headers`, so `fixincludes` never runs and GCC's bootstrap `include/limits.h` is the only file user code reaches when it does `#include <limits.h>`. That file is a placeholder (`MB_LEN_MAX=1`, no `PATH_MAX`, no POSIX). glibc 2.40's fortified `<stdlib.h>` has `#if defined(MB_LEN_MAX) && MB_LEN_MAX != 16 #error`, which trips any gnulib code (m4, sed, coreutils, ...). The fix: after glibc install, (a) prepend `#define _GCC_LIMITS_H_; #include_next <limits.h>` to GCC's bootstrap limits.h, and (b) drop a copy of glibc's `limits.h` into the empty `include-fixed/` dir so `include_next` lands there. Together this wires `<limits.h>` → glibc → `bits/posix1_lim.h` → `linux/limits.h` (PATH_MAX=4096).

2. **`02-temp-tools.sh` builds binutils-pass2 AND gcc-pass2** — LFS book chapter 6.17–6.18. These install native-named `gcc`/`cc`/`ld`/`ar`/... into `$LFS/usr/bin/` so the chroot has a working compiler with no `aarch64-lfs-linux-gnu-` prefix. Without this, the chroot stage's binutils-pass2 config errors with "no acceptable C compiler found in $PATH".

3. **`02-temp-tools.sh` creates `/bin`, `/sbin`, `/lib` as symlinks BEFORE any package install** — util-linux's install writes `mount`/`umount` to `/bin/` and `agetty` to `/sbin/`. If those exist as real dirs (because we made them late) the symlinks go inside them (`/bin/bin -> usr/bin`). With symlinks created first, util-linux's writes follow through to `/usr/bin/`.

4. **`02-temp-tools.sh` linker scripts for ncurses libs** — ncurses is built `--enable-widec --without-normal --with-shared`, which only produces `lib*w.so`. Later packages (util-linux's `ul`, openssh) link `-ltinfo`/`-lncurses`/`-lform`/etc. We drop GNU ld linker scripts at `$LFS/usr/lib/libfoo.so` that say `INPUT(-lfoow)`, and `libtinfo.so` redirects to `-lncursesw` because we don't pass `--with-termlib` (tinfo lives inside libncursesw).

5. **`03-chroot.sh` generates `/repo/versions.env`** — the chroot has no jq (not in manifest). All package versions/URLs from `manifest.json` get pre-resolved into a shell-sourceable env file on the builder side; `03b-chroot-inner.sh` sources it instead of running jq.

6. **`03b-chroot-inner.sh` uses per-package markers under `/var/lib/lfs-pkgs/`** — each special-case block and the generic loop wrap their build in `pkg_skip <name> && continue` / `pkg_mark <name>`. Retries after a single-package failure skip the 25+ packages already built.

7. **`03b-chroot-inner.sh` exports `FORCE_UNSAFE_CONFIGURE=1`** — coreutils' configure refuses to run as root without this. The chroot stage is necessarily root (we just `chroot`'d in without dropping privileges, per LFS chapter 7 convention).

8. **`03b-chroot-inner.sh` patches `Modules/_uuidmodule.c` in the Python build** — configure detects `HAVE_UUID_GENERATE_TIME_SAFE` via a link test, but our libuuid's `<uuid/uuid.h>` doesn't expose the prototype. C11 treats the implicit declaration as a hard error. We prepend `#include <uuid/uuid.h>` + an explicit `extern int uuid_generate_time_safe(unsigned char *out);` before the function uses it.

9. **`04-finalize.sh` chmod -x's `rc.dbus` and `rc.elogind`** — those services are deferred (meson/python bootstrap not done). Leaving the scripts +x would just spam errors on every boot when rc.M tries to start nonexistent binaries.

10. **`04-finalize.sh` creates `/var/lib/dhcpcd` with uid/gid 52** — dhcpcd drops privileges to a `dhcpcd` user (seeded in `03b-chroot-inner.sh`'s `/etc/passwd` and `/etc/group`) and chdirs to its home. Without the dir, dhcpcd silently fails to acquire a lease — no network, no smoke test pass.

11. **`grub.cfg` uses `root=/dev/vda2 rootfstype=ext4 rootwait`** (not `root=LABEL=...`) — virtio-blk takes ~165ms to probe, but the kernel tries to mount root before that. LABEL lookup fails because no block devices have been registered yet. `/dev/vda2` + `rootwait` makes the kernel wait for the device. Console order is `console=tty1 console=hvc0` so `/dev/console` is `hvc0` (visible via `tart run --serial`).

12. **`tools/build-all.sh` installs the host SSH key into `/mnt/lfs/root/.ssh/authorized_keys`** before mkimage. sshd defaults to `PermitRootLogin prohibit-password` which accepts pubkey even when root's password is locked.

13. **`tools/build-all.sh` runs mkimage inside the VM, not on the host** — mkimage uses `sgdisk`, `losetup`, `mkfs.ext4`, `grub-mkimage` — all Linux-only. Then it rsyncs the produced `disk.img` back to the host and runs `tart-import.sh` for the Tart side (which `tart create --linux` to get a valid config.json/nvram.bin baseline, then swaps in our disk).

14. **`scripts/tart-helpers.sh:tart_ip` has an ARP fallback** — `tart ip` reads `/var/db/dhcpd_leases` which is populated only when Apple's `bootpd` recognizes the client. Our `dhcpcd` exchange somehow doesn't leave a lease entry bootpd matches, but the IP IS in the macOS ARP cache. We look up by `macAddress` from `~/.tart/vms/<vm>/config.json`. macOS arp strips leading zeros from each octet (`ca:00:26` → `ca:0:26`); we normalize both sides before comparing.

## Persistence gotcha: ext4 commit=30 + tart stop

The cirruslabs Ubuntu image mounts `/` as ext4 with `commit=30`, meaning the journal flushes at most every 30 seconds. **Writes within ~30s of `tart stop` can be silently lost on the next boot.** Historical symptoms: SSH keys vanishing, stage markers disappearing, `chattr +i` being undone.

All shipped scripts sync before `tart stop`. If you add a new script that issues `tart stop`, **add a `sudo sync; sync` over SSH first**. Same for any in-VM script that writes state at the very end.

## Source download reliability

`tools/fetch-sources.sh` retries via mirrors: `ftp.gnu.org/gnu/<path>` → `ftpmirror.gnu.org/<path>` → `mirrors.kernel.org/gnu/<path>`; `cdn.kernel.org/<path>` → `mirrors.edge.kernel.org/<path>`. curl uses `--speed-time 30 --speed-limit 1024` to kill stalled streams in 30s instead of 30min.

Pre-fetching on the host (Stage 0 of `phase2.sh`) is the most reliable because the Mac's network is faster and more stable than the VM's NAT'd virtio-net link. `build-all.sh` rsyncs `cache/sources/` into the builder at `/mnt/lfs/sources/`, and the in-VM `fetch` stage becomes a sha256 verification pass.

## Common failures (now-fixed; documented in case they regress)

These are all handled by the current pipeline. They're listed here so a future bisect or version bump can recognize them quickly:

- **`temp-tools` failing on m4-1.4.19** → m4 ≤1.4.19 has a gnulib bug against glibc 2.40 (gnulib's `<stdlib.h>` shim doesn't include `<limits.h>` before glibc's fortification check). Fix: bump to m4 1.4.20.
- **`temp-tools` package error "Assumed value of MB_LEN_MAX wrong" or "PATH_MAX undeclared"** → cross-toolchain header chain. See item 1 above.
- **`chroot` failing on shadow with "readpassphrase() is missing"** → shadow ≥4.16 wants libbsd's readpassphrase. LFS uses `--without-libbsd`. See `03b-chroot-inner.sh`'s shadow block.
- **`chroot` failing on util-linux with "liblastlog2 selected, but required sqlite3"** → util-linux's generic configure pulls in liblastlog2 which needs sqlite3. We pass `--disable-liblastlog2`.
- **`chroot` failing on Python 5.40.0's `locale.c`** → `PERL_LC_ALL_CATEGORY_POSITIONS_INIT` codegen bug. Pin to 5.38.2 (LTS line).
- **`finalize` produces a kernel that won't boot ("VFS: Unable to mount root fs on unknown-block(0,0)")** → kernel cmdline used `root=LABEL=...` but virtio-blk probes after kernel tries to mount. See item 11.
- **Image boots but `tart ip` returns "no IP address found"** → Apple's bootpd doesn't log dhcpcd-style leases. See item 14.
- **Smoke test gets "Permission denied (publickey,password,keyboard-interactive)"** → host SSH key not installed in /root. See item 12; check `~/.ssh/id_ed25519.pub` exists before running `build-all.sh`.

## Phase 3 next steps (preview)

With `gnunix-base-0.1.0` booting and SSH-reachable:

1. Install the multi-user Nix daemon (ADR-003) — the static base now delegates userland to dynamic Nix.
2. Bring back dbus + elogind via either a meson/python bootstrap in stage 2, or a Nix-managed install in stage 3.
3. Move to Phase 4 (Wayland session via `gnunix-desktop`).
