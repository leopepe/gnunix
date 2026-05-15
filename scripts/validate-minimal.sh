#!/bin/sh
# validate-minimal.sh <vm-name>
# Boots an gnunix-minimal Tart image and runs Phase 3 post-boot checks.
# Exits 0 on success; non-zero with a one-line reason on failure.

set -eu
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$REPO_ROOT/scripts/tart-helpers.sh"

VM=${1:-}
[ -z "$VM" ] && { echo "usage: $0 <vm-name>" >&2; exit 1; }

echo "[validate-minimal] starting $VM"
tart run --no-graphics "$VM" >/dev/null 2>&1 &
TART_PID=$!
trap 'tart stop "$VM" >/dev/null 2>&1 || true; kill $TART_PID 2>/dev/null || true' EXIT

echo "[validate-minimal] waiting for ssh"
if ! tart_wait_ssh "$VM" root; then
  echo "FAIL: ssh did not become available within 120s"
  exit 1
fi

echo "[validate-minimal] running smoke checks"
tart_ssh "$VM" root sh -c '
  set -e
  echo "uname: $(uname -a)"
  # Make /nix tools available even if /etc/profile.d/nix-daemon.sh did not
  # get sourced by this non-login shell.
  export PATH="/nix/var/nix/profiles/default/bin:$PATH"

  # 1. nix binaries present.
  command -v nix       >/dev/null || { echo "FAIL: nix not on PATH"; exit 2; }
  command -v nix-store >/dev/null || { echo "FAIL: nix-store not on PATH"; exit 3; }

  # 2. report versions.
  nix --version
  nix-store --version

  # 3. multi-user daemon running.
  pidof nix-daemon >/dev/null \
    || { echo "FAIL: nix-daemon not running (rc.nix-daemon enabled?)"; exit 4; }

  # 4. store db query works.
  nix-store -q --hash /nix/var/nix/profiles/default >/dev/null \
    || { echo "FAIL: nix-store cannot query the default profile"; exit 5; }

  # 5. nixbld* users present.
  getent passwd nixbld1  >/dev/null || { echo "FAIL: nixbld1 user missing";  exit 6; }
  getent passwd nixbld32 >/dev/null || { echo "FAIL: nixbld32 user missing"; exit 7; }
  getent group  nixbld   >/dev/null || { echo "FAIL: nixbld group missing";  exit 8; }

  # Warnings: things deferred from Phase 2 that still aren'\''t here.
  pidof sshd        >/dev/null || echo "WARN: sshd not running"
  pidof dbus-daemon >/dev/null || echo "WARN: dbus not running (still deferred)"

  echo "[validate-minimal] PASS"
'
