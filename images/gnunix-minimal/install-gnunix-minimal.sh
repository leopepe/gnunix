#!/bin/bash
# images/gnunix-minimal/install-gnunix-minimal.sh — runs INSIDE the gnunix-minimal-build VM as root.
#
# Manually installs Nix from a binary release tarball, multi-user mode,
# WITHOUT systemd. The official `install-multi-user` script wants systemd
# (or launchd on macOS) and aborts on sysvinit; we replicate what it does
# but use our own /etc/rc.d/rc.nix-daemon for daemon supervision (ADR-001).
#
# Called by images/gnunix-minimal/build.sh after scp'ing the tarball to /root/.
# Tarball path can be overridden via $NIX_TARBALL.
#
# Idempotent: re-running on an already-installed system is a no-op for
# users/dirs, re-copies store contents (harmless), rewrites configs.

set -euo pipefail

NIX_TARBALL="${NIX_TARBALL:-/root/nix-2.24.10-aarch64-linux.tar.xz}"
NIX_BUILD_GROUP_ID=30000
NIX_BUILD_USERS=32

# Known store paths in the tarball (from install-multi-user.sh in the same tarball).
NIX_INSTALLED_NIX="/nix/store/30gnc15nig1awa11vii9yz3z8518rnr3-nix-2.24.10"
NIX_INSTALLED_CACERT="/nix/store/9m6xbd8pcdb6c655b7lifhi5m1igi5rk-nss-cacert-3.101"

[ -f "$NIX_TARBALL" ] || { echo "[install-nix] tarball missing: $NIX_TARBALL" >&2; exit 1; }

# Extract somewhere with room (tmpfs /tmp is small; /root is on ext4 root).
WORK=$(mktemp -d -p /root nix-bootstrap.XXXX)
trap 'rm -rf "$WORK"' EXIT

echo "[install-nix] extracting tarball to $WORK"
tar -xf "$NIX_TARBALL" -C "$WORK"
SRC=$(ls -d "$WORK"/nix-*-aarch64-linux)
[ -d "$SRC/store" ] || { echo "[install-nix] tarball missing store/"; exit 1; }
[ -f "$SRC/.reginfo" ] || { echo "[install-nix] tarball missing .reginfo"; exit 1; }

echo "[install-nix] creating nixbld group + $NIX_BUILD_USERS users"
if ! getent group nixbld >/dev/null; then
  groupadd -r -g "$NIX_BUILD_GROUP_ID" nixbld
fi
for i in $(seq 1 "$NIX_BUILD_USERS"); do
  if ! getent passwd "nixbld$i" >/dev/null; then
    useradd -r -M -N -d /var/empty -s /usr/bin/false \
      -g "$NIX_BUILD_GROUP_ID" -G nixbld \
      -u $(( NIX_BUILD_GROUP_ID + i )) "nixbld$i"
  fi
done

echo "[install-nix] creating /nix layout"
install -d -m 0755                  /nix
install -d -m 1775 -g nixbld        /nix/store
install -d -m 0755                  /nix/var
install -d -m 0755                  /nix/var/log
install -d -m 0755                  /nix/var/log/nix
install -d -m 0755                  /nix/var/log/nix/drvs
install -d -m 0755                  /nix/var/nix
install -d -m 0755                  /nix/var/nix/db
install -d -m 0755                  /nix/var/nix/gcroots
install -d -m 0755                  /nix/var/nix/profiles
install -d -m 0755                  /nix/var/nix/temproots
install -d -m 0755                  /nix/var/nix/userpool
install -d -m 1777                  /nix/var/nix/gcroots/per-user
install -d -m 1777                  /nix/var/nix/profiles/per-user
install -d -m 0700                  /nix/var/nix/profiles/per-user/root

echo "[install-nix] copying store paths from tarball"
# -a preserves perms/times/symlinks. cp -a target/. preserves hidden files.
cp -a "$SRC/store/." /nix/store/

echo "[install-nix] initializing store database (--load-db)"
"$NIX_INSTALLED_NIX/bin/nix-store" --load-db < "$SRC/.reginfo"

echo "[install-nix] installing bootstrap nix + cacert into the default profile"
# HOME must be set so nix-env writes the per-user state somewhere sane.
HOME=/root "$NIX_INSTALLED_NIX/bin/nix-env" -i "$NIX_INSTALLED_NIX" \
  --profile /nix/var/nix/profiles/default
HOME=/root "$NIX_INSTALLED_NIX/bin/nix-env" -i "$NIX_INSTALLED_CACERT" \
  --profile /nix/var/nix/profiles/default

echo "[install-nix] writing /etc/nix/nix.conf"
install -d -m 0755 /etc/nix
cat > /etc/nix/nix.conf <<'EOF'
# Multi-user Nix daemon config.
build-users-group = nixbld
sandbox = true
extra-experimental-features = nix-command flakes
extra-trusted-users = root
EOF

echo "[install-nix] writing /etc/profile.d/nix-daemon.sh"
install -d -m 0755 /etc/profile.d
cat > /etc/profile.d/nix-daemon.sh <<'EOF'
# Multi-user Nix shell integration.
# Sourced by /etc/profile when /nix is present.
if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi
export NIX_SSL_CERT_FILE=/nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt
EOF
chmod 0644 /etc/profile.d/nix-daemon.sh

# System-wide CA bundle: point the standard /etc/ssl/certs/ca-certificates.crt
# at the Nix-installed bundle so non-Nix tools also use it.
install -d -m 0755 /etc/ssl/certs
[ -f /etc/ssl/certs/ca-certificates.crt ] && \
  mv -f /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt.pre-nix || true
ln -sfn /nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt \
  /etc/ssl/certs/ca-certificates.crt

echo "[install-nix] writing /etc/rc.d/rc.nix-daemon (with nohup/detached stdio)"
# Overwrite even if gnunix-base shipped a version — older copies don't detach
# stdio, which makes any SSH session that calls 'rc.nix-daemon start' hang
# forever waiting on the daemon's fds.
cat > /etc/rc.d/rc.nix-daemon <<'RCEOF'
#!/bin/sh
# /etc/rc.d/rc.nix-daemon — multi-user Nix daemon supervisor.

NIXD=/nix/var/nix/profiles/default/bin/nix-daemon
PIDFILE=/run/nix-daemon.pid

case "${1:-start}" in
  start)
    if [ ! -x "$NIXD" ]; then
      echo "[rc.nix-daemon] $NIXD not found; skipping"
      exit 0
    fi
    mkdir -p /var/log
    # Detach stdio (the daemon outlives the caller; without this, SSH hangs).
    nohup "$NIXD" --daemon </dev/null >>/var/log/nix-daemon.log 2>&1 &
    echo $! > "$PIDFILE"
    ;;
  stop)
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null
    rm -f "$PIDFILE"
    ;;
  *) echo "usage: $0 {start|stop}"; exit 1 ;;
esac
RCEOF
chmod +x /etc/rc.d/rc.nix-daemon

echo "[install-nix] verifying"
/nix/var/nix/profiles/default/bin/nix --version
/nix/var/nix/profiles/default/bin/nix-store --version

# Daemon is intentionally NOT started here — let rc.M start it on the next
# boot. Running 'rc.nix-daemon start' over the same SSH session has caused
# the orchestrator to hang in the past (descendant fds keeping ssh alive),
# and the daemon's first run is better observed via the actual boot.

echo "[install-nix] DONE — reboot to bring nix-daemon up via rc.M"
