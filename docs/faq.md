# GNUnix user-workflows FAQ

This FAQ answers common "how do I install X on GNUnix?" questions, grouped
by the kind of thing being installed. It is workflow-oriented; for
"why is the system designed this way?" see the ADRs under
[`docs/adrs/`](adrs/).

Every answer points back to the architectural decision it relies on, so
you can tell which parts are policy and which are mechanism.

## Mental model: four places to install things

GNUnix has exactly four destinations for software. Pick by **who** needs
the thing and **when** it must be present.

| Destination | Who sees it | When | Examples |
|---|---|---|---|
| **LFS base** (compiled from source into `/`) | Everyone, including init | Before `nix-daemon` is up | Kernel, kernel modules, firmware, `glibc`, `bash`, `sysvinit` |
| **System Nix profile** (`/nix/var/nix/profiles/system`) | Every user, system-wide | After `nix-daemon` is up, started by rc.d | Compositors, dbus, elogind, daemons, shared services |
| **User home-manager profile** (`~/.nix-profile`) | One user | Login shell onwards | CLIs, editors, browsers, per-user dotfiles |
| **Project-local** (`shell.nix`, `mise`, `uv`, `pnpm`, etc.) | One project | When you `cd` in | Language toolchains, project-pinned dev deps |

Decision flow:

1. *Does the kernel or init need it before Nix is up?* → LFS base.
   Otherwise it's Nix.
2. *Do multiple users need it, or is it a daemon launched at boot?* →
   System Nix profile + an `rc.d` script.
3. *Is it the user's choice (editor, shell, browser, fonts)?* →
   home-manager.
4. *Is it pinned to one project?* → project-local toolchain.

When unsure, default **down** the table (toward user-space). It's easier
to promote a per-user install to system-wide than to extract a
system-wide install back into a user profile.

---

## Q1: How do I install a CLI tool like `mise`?

`mise` is in nixpkgs. Pick the level that matches the use case.

**Ad-hoc, no install:**

```sh
nix shell nixpkgs#mise
```

**Imperative user install:**

```sh
nix profile install nixpkgs#mise
```

**Declarative via home-manager** — the right default for any tool you
expect to keep using:

```nix
# home.nix
{ pkgs, ... }: {
  programs.mise = {
    enable = true;
    enableBashIntegration = true;   # or enableZshIntegration / enableFishIntegration
  };
}
```

The home-manager module handles shell activation; you don't need the
manual `eval "$(mise activate ...)"` line.

> **Why home-manager and not the system profile?** `mise` is a personal
> tool — version selections live in `~/.config/mise/`, and there's no
> reason user B's choices should follow user A. ADR-004 reserves
> home-manager for exactly this kind of user-scoped declarative config.

---

## Q2: How do I install system-wide tooling like wifi managers or drivers?

This one splits across layers — that's the whole point of the GNUnix
sandwich.

| Thing | Layer | Why |
|---|---|---|
| Wifi chip driver (kernel module) | LFS base kernel | Built `=m`, auto-loaded by eudev MODALIAS, per ADR-012 |
| Firmware blobs (`iwlwifi-*.ucode`, etc.) | LFS base, `/lib/firmware` | Kernel loads these at module init, before `/nix` is even mounted |
| Wifi userland daemon (`iwd`, `wpa_supplicant`) | System Nix profile + `rc.d` script | Daemon — needs to start at boot, must be on every user's PATH |
| CLI tools (`iwctl`, `nmcli`) | Falls out of the daemon package | — |

**Adding a daemon to the system profile:**

```nix
# images/gnunix-minimal/system.nix (sketch)
{ pkgs ? import <nixpkgs> {} }:

pkgs.buildEnv {
  name = "gnunix-system";
  paths = with pkgs; [
    iwd
    wpa_supplicant
    # ...dbus, elogind, etc. per ADR-009
  ];
}
```

Realise it once:

```sh
nix-env -p /nix/var/nix/profiles/system -i -f system.nix
```

**Launching it at boot** — one rc.d script per service, Slackware style
(ADR-001):

```sh
# /etc/rc.d/rc.iwd     (chmod +x to enable; chmod -x to disable)
#!/bin/sh
set -eu
exec /nix/var/nix/profiles/system/bin/iwd
```

**What does *not* belong in Nix:**

- **Drivers** — they live in the kernel image. If a chip isn't
  supported, edit `images/gnunix-base/kernel.config`, not a package
  list. Per ADR-008, kernel changes need human review.
- **Firmware** — `/lib/firmware` is base-layer. Pulling firmware
  through Nix means `nix-daemon` has to be up before networking, which
  is a dependency loop you don't want to debug at 2am.
- **NetworkManager** — works, but pulls D-Bus policy and a lot of
  GNOME-adjacent assumptions. `iwd` is the simpler default; if you want
  NM instead, open an ADR amendment first.

---

## Q3: How do I install a new Wayland compositor system-wide?

This is the canonical "system-wide Nix" case in GNUnix — ADR-009 and
ADR-020 document exactly this pattern.

**Why the system profile makes it multi-user for free:**

`/nix/var/nix/profiles/system/bin` is on every user's `PATH` via
`/etc/profile`. Anything in that profile is system-wide. The Nix store
itself (`/nix/store/...`) is read-execute for everyone, so all users
share the same binary on disk.

**Concrete shape** — say you want to add `niri` (a real Wayland
compositor in the i3 spirit) alongside the default Hyprland:

1. Bundle the compositor + its portal + its `.desktop` entry:

   ```nix
   # bundles/niri.nix
   { pkgs }:
   {
     packages = with pkgs; [
       niri
       xdg-desktop-portal-gnome    # niri uses the gnome portal
       xwayland-satellite          # on-demand XWayland, optional
       alacritty                   # session-default terminal
     ];

     sessionDesktop = pkgs.writeTextFile {
       name = "niri-session";
       destination = "/share/wayland-sessions/niri.desktop";
       text = ''
         [Desktop Entry]
         Name=Niri
         Exec=niri-session
         Type=Application
       '';
     };
   }
   ```

2. Compose into the image's `session.nix`:

   ```nix
   # images/gnunix-desktop/session.nix
   { pkgs ? import (fetchTarball /* pinned in tools/manifest.json */) {} }:

   let
     hyprland = import ../../bundles/hyprland.nix { inherit pkgs; };
     niri     = import ../../bundles/niri.nix     { inherit pkgs; };
   in
   pkgs.buildEnv {
     name  = "gnunix-desktop-system";
     paths =
       hyprland.packages ++ [ hyprland.sessionDesktop ] ++
       niri.packages     ++ [ niri.sessionDesktop ] ++
       (with pkgs; [ dbus elogind greetd seatd ]);
   }
   ```

3. Realise into the system profile:

   ```sh
   nix-env -p /nix/var/nix/profiles/system -i -f images/gnunix-desktop/session.nix
   ```

4. `greetd` reads `/nix/var/nix/profiles/system/share/wayland-sessions/`
   and the new compositor appears in the session menu for every user.

**What *not* to do:**

- Don't install a compositor via home-manager. It works for one user,
  but the `.desktop` file won't be in greetd's search path, and user B
  has to reinstall. Compositors are infrastructure, not preference.
- Don't add a NixOS module wrapper — ADR-004 rules them out.
- Don't forget the portal. A Wayland compositor without
  `xdg-desktop-portal-*` works until something tries to open a file
  picker, then fails opaquely.

**Per-user tweaks** (keybinds, autostarts, themes) still go in each
user's `home.nix`. The system layer ships the binary and the session
entry; the user owns the config.

If you're adding a compositor as a *first-class* installer option, this
is also an ADR-020 amendment (it locks "sway / hyprland / labwc" as the
three installer profiles). Don't expand the TUI silently.

---

## Q4: How do I install Kubernetes and run it at boot?

**First, an architectural sanity check.** ADR-005 locks GNUnix as a
*developer workstation*, not a server. Running k8s as a system service
that always boots is server-shaped. Two paths:

- **You want a local cluster for development** — install `kind` or
  `minikube` via home-manager and start a cluster only when you need
  one. Zero ADR friction. This is the answer for ~90% of cases.
- **You want k8s always-on, system-wide** — this is real work; open an
  ADR amendment first so the deviation from ADR-005 is recorded.

The mechanism for the always-on case is the same as any other daemon.
For a workstation, use **k3s** (single static binary, embedded etcd +
containerd + CNI) rather than upstream `kubelet` + `kubeadm` — full
upstream is five daemons and a lot of rc.d glue.

**System profile piece** (per ADR-009):

```nix
# bundles/k3s.nix
{ pkgs }:
{
  packages = with pkgs; [
    k3s         # bundles containerd, runc, CNI internally
    kubectl     # host-side tooling
  ];
}
```

Compose into the desktop image's `session.nix` and realise into
`/nix/var/nix/profiles/system`. Now `k3s` and `kubectl` are on every
user's PATH.

**rc.d piece** (per ADR-001):

```sh
# /etc/rc.d/rc.k3s     (chmod +x to enable)
#!/bin/sh
set -eu

BIN=/nix/var/nix/profiles/system/bin/k3s
LOG=/var/log/k3s.log
PID=/var/run/k3s.pid

start() {
  setsid "$BIN" server \
    --data-dir /var/lib/k3s \
    >>"$LOG" 2>&1 < /dev/null &
  echo $! > "$PID"
}

stop() {
  [ -f "$PID" ] && kill "$(cat "$PID")" && rm -f "$PID"
}

case "${1:-start}" in
  start) start ;;
  stop)  stop ;;
  *) echo "usage: $0 {start|stop}" >&2; exit 1 ;;
esac
```

**Kernel prerequisites** — this is the part most people skip and then
spend two days debugging. Edit `images/gnunix-base/kernel.config`:

| Feature | Needed for |
|---|---|
| `CGROUPS=y`, `MEMCG=y`, `CPUSETS=y`, `BLK_CGROUP=y`, `PIDS_CGROUP=y` | cgroup v2 (kubelet hard-requires it) |
| `NAMESPACES=y` and sub-namespaces (`USER_NS`, `PID_NS`, `NET_NS`) | containers |
| `OVERLAY_FS=m` | container image layers (already added for the live ISO, ADR-017) |
| `BRIDGE=m`, `VETH=m`, `VLAN_8021Q=m`, `IP_VS=m` | CNI + kube-proxy |
| `NF_NAT=m`, `NF_CONNTRACK=m`, `NF_TABLES=m` | iptables / nftables rules |
| `BPF_SYSCALL=y`, `BPF_JIT=y` | modern kube-proxy / cilium |

Per ADR-008, kernel changes get **human review** and ship in their own
commit. Don't bundle them with the rc.d script.

**Mounts** — cgroup v2 must be mounted before k3s starts. If not
already handled, add to `rc.S`:

```sh
mountpoint -q /sys/fs/cgroup || mount -t cgroup2 none /sys/fs/cgroup
```

**Anti-patterns:**

- Don't try to put container images in `/nix/store`. k3s owns
  `/var/lib/k3s`; nix-daemon owns `/nix/store`. Cross the streams and
  things break in opaque ways.
- Don't reach for `services.k3s.enable = true` — that's NixOS, which
  ADR-004 doesn't accept. The rc.d script is the equivalent.

---

## Q5: I'm a web developer (React / Next.js / TypeScript) — how do I set up Node, package managers, and local backend services?

GNUnix doesn't ship a "Node stack" by default — that's a user choice,
per the locked decisions. Compose your own.

**Node version management** — three reasonable paths:

| Approach | When to use |
|---|---|
| `mise` (Q1) | Per-project Node version, switching often, want fast activation |
| home-manager `pkgs.nodejs_22` | Single global Node, infrequent upgrades |
| `nix-direnv` + project `shell.nix` | Each project pins its own toolchain reproducibly |

For most web dev workflows, **`mise` is the right default.** It handles
Node, pnpm, Bun, and Deno from one tool, swaps versions per-directory,
and stays out of Nix's way.

```nix
# home.nix
{ pkgs, ... }: {
  programs.mise = {
    enable = true;
    enableBashIntegration = true;
    globalConfig = {
      tools = {
        node = "22";
        pnpm = "latest";
      };
    };
  };
}
```

**Package managers** — `npm` comes with Node. `pnpm`, `yarn`, and `bun`
are in nixpkgs and via `mise`. Pick one per project and stick to it.

**Browsers for testing:**

```nix
# home.nix
home.packages = with pkgs; [
  firefox
  chromium
  # for Playwright:
  playwright-driver.browsers   # bundles its own; set PLAYWRIGHT_BROWSERS_PATH
];

home.sessionVariables.PLAYWRIGHT_BROWSERS_PATH =
  "${pkgs.playwright-driver.browsers}";
```

Playwright is the one fiddly piece — it wants to download its own
Chromium/Firefox, which doesn't play well with Nix's read-only store.
The `playwright-driver.browsers` package + `PLAYWRIGHT_BROWSERS_PATH`
env var is the standard workaround.

**Editors / IDEs:** install via home-manager. VS Code:

```nix
programs.vscode = {
  enable = true;
  package = pkgs.vscode;   # or pkgs.vscodium for the open-source build
};
```

**Local backend services** (Postgres, Redis, etc.):

- *Throwaway / per-project* → run them in containers, started by
  whatever dev tool you prefer (`docker compose`, `devenv`, `process-compose`).
  See Q7 for a multi-user shared service.
- *Persistent / shared* → install into the system Nix profile + rc.d.
  See Q7.

**What about Docker Desktop?** Don't install it on the guest — you're
already in a VM. If you need an OCI runtime, install `podman` or
`docker` (the CLI + daemon) via the system Nix profile and an rc.d
script — same daemon pattern as everything else.

---

## Q6: I'm a data scientist using Python and Anaconda — how does that fit with Nix?

There's real friction between Anaconda and Nix-style systems, and it's
worth understanding before you pick a path.

**The conflict:** conda installs prebuilt binaries that expect FHS paths
(`/usr/bin/python`, `/lib/x86_64-linux-gnu/...`). GNUnix doesn't have
those — its Python lives at `/nix/store/...-python-3.x/bin/python`.
Conda environments that work on Ubuntu often `ImportError` on dynamic
libraries here.

**Three options, ranked:**

### Option 1 — Nix-native Python + `uv` (recommended)

Modern Python tooling has caught up to the point where `uv` (or
`poetry`) handles everything conda used to, faster, and without the
FHS conflict.

```nix
# home.nix
{ pkgs, ... }: {
  home.packages = with pkgs; [
    python312
    uv                     # fast resolver + venv manager
    pipx                   # for global Python CLI tools
    # Scientific stack — let Nix build it:
    (python312.withPackages (ps: with ps; [
      numpy pandas scipy matplotlib
      jupyter ipykernel
      scikit-learn
    ]))
  ];
}
```

Per-project work then uses plain venvs on top of the Nix Python:

```sh
cd myproject
uv venv
uv pip install -r requirements.txt
```

This is the cleanest path. Reproducible, no FHS hackery, and `uv` is
fast enough that you won't miss conda's caching.

### Option 2 — `pkgs.anaconda3`

Anaconda is packaged in nixpkgs (`pkgs.anaconda3` or `pkgs.conda`), but
lags upstream and won't auto-update channels. Useful if your team has
shared `environment.yml` files you must consume verbatim.

```nix
home.packages = [ pkgs.anaconda3 ];
```

Caveat: any conda env that installs binary wheels with embedded RPATHs
will still hit the FHS issue. Wrap with `nix-ld` or `buildFHSEnv` if
you must:

```nix
home.packages = [
  (pkgs.buildFHSEnv {
    name = "conda-fhs";
    targetPkgs = ps: with ps; [ anaconda3 stdenv.cc.cc.lib zlib ];
    runScript = "bash";
  })
];
```

Then `conda-fhs` drops you into a shell where conda envs behave like
they would on Ubuntu.

### Option 3 — `nix-ld`

`nix-ld` provides a fake dynamic loader at `/lib/ld-linux-*.so` that
forwards to Nix-store libraries. Lets unmodified Linux binaries
(including conda installs, pip wheels with C extensions, pre-built ML
tooling) "just work."

This is system-wide, so it goes in the system Nix profile + a small
config snippet, not home-manager. Use it as a last resort — it's a wart
on the architecture, but for some ML toolchains there's no alternative.

**Jupyter:**

For a single user, the Python expression in Option 1 with `jupyter` and
`ipykernel` is enough — `jupyter lab` works out of the box. For a
shared Jupyter server multiple users hit, treat it like Postgres in Q7
(system profile + rc.d, bind to localhost).

**GPU / accelerated ML:** GNUnix runs in a Tart VM on Apple Silicon.
There is no NVIDIA passthrough, and Metal isn't exposed to the Linux
guest. If your work needs CUDA, you'll do it on the macOS host (or
remote), not in the GNUnix VM. This isn't a GNUnix limitation per se —
it's the price of the Tart-on-Mac choice in ADR-005.

---

## Q7: Multiple users on the same workstation need a shared Postgres (or Redis, etc.) — how?

Same pattern as Q3 / Q4: system Nix profile + rc.d script. Per
ADR-003's multi-user nix-daemon, GNUnix explicitly supports multiple
users on one machine; shared services are a natural extension.

**Example — shared Postgres:**

```nix
# bundles/postgres.nix
{ pkgs }:
{
  packages = with pkgs; [ postgresql_16 ];
}
```

Compose into the system `session.nix`, realise the profile, then add
the daemon and a one-shot initdb:

```sh
# /etc/rc.d/rc.postgres     (chmod +x to enable)
#!/bin/sh
set -eu

BIN=/nix/var/nix/profiles/system/bin
DATA=/var/lib/postgresql/16
PGUSER=postgres

# One-shot init on first boot.
if [ ! -d "$DATA" ]; then
  install -d -o "$PGUSER" -g "$PGUSER" -m 0700 "$DATA"
  su -s /bin/sh "$PGUSER" -c "$BIN/initdb -D $DATA --auth=trust --no-locale"
fi

exec su -s /bin/sh "$PGUSER" -c \
  "$BIN/postgres -D $DATA -k /var/run/postgresql"
```

The `postgres` system user is created in the LFS base (it's a static
UID), not via Nix. Add it to `/etc/passwd` in the base image build —
this is the rare case where adding to the base layer is correct
(system accounts are install-time, not runtime, state).

**How users connect:**

- *Unix socket* — `psql -h /var/run/postgresql` works for any user with
  read access to the socket directory. Set the directory mode in the
  rc.d script if you want to restrict it to a `dbusers` group.
- *Localhost TCP* — `psql -h 127.0.0.1` after editing `pg_hba.conf` to
  allow local connections. Standard Postgres operations from here.

**The same pattern works for:**

- **Redis** — `pkgs.redis` + `rc.redis` binding to `127.0.0.1:6379`.
- **MinIO** — `pkgs.minio` + `rc.minio` with shared bucket dir under
  `/var/lib/minio`.
- **A shared Jupyter server** — `pkgs.python3.withPackages (ps: [
  ps.jupyterlab ])` + `rc.jupyter` binding to a localhost port; users
  hit it from their browsers.
- **Local LLM inference** (`ollama`, `llama.cpp`) — same pattern,
  bound to localhost.

**Anti-patterns:**

- Don't make each user run their own Postgres on a different port.
  That's what "multi-user workstation" stops being useful for. Pick one
  service, manage it system-wide, share it.
- Don't run shared services via `systemctl --user` style setups.
  They don't exist here (ADR-001), and even if they did, "shared
  service started by one user" is the wrong ownership model.
- Don't put data dirs (`/var/lib/postgresql`, `/var/lib/redis`) inside
  `/nix/store`. The store is read-only by design; service state lives
  in `/var/lib/<service>`.

---

## Cross-cutting anti-patterns

A roll-up of the "don't do this" notes that appear in multiple
answers, in case you only read one section:

- **Don't install daemons via home-manager.** They start per-user
  at login, not at boot, and other users can't see them. Daemons →
  system profile + rc.d.
- **Don't install user CLIs into the system profile.** They get
  shared across users that didn't ask for them, and updates require
  re-realising the system env. CLIs → home-manager.
- **Don't reach for NixOS modules.** ADR-004 doesn't accept them.
  Anything you'd write as a `services.X.enable = true` becomes a
  `buildEnv` entry plus an `rc.d` script here.
- **Don't bundle kernel changes with package changes.** Kernel /
  glibc / binutils / sysvinit / eudev / dbus / elogind / GRUB are
  on ADR-008's human-review list. Their own commit, their own PR.
- **Don't put service state in `/nix/store`.** The store is
  read-only and content-addressed. Service data lives in
  `/var/lib/<service>`; logs in `/var/log/<service>`.
- **Don't add "fallback" or "compatibility" layers** for
  hypothetical future requirements. If a tool needs a wart (FHS env
  for conda, `nix-ld` for pre-built binaries), add the smallest
  wart that works, not a generic abstraction.

---

## Related reading

- [`docs/architecture.md`](architecture.md) — image lineage, build
  pipeline, and where each piece lives.
- [`docs/adrs/`](adrs/) — the locked decisions referenced above.
- [`docs/runbooks/`](runbooks/) — task-oriented procedures (build,
  release, test).
- [`CLAUDE.md`](../CLAUDE.md) — the guiding philosophy and locked-
  decisions summary table.
