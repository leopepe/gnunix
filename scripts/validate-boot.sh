#!/bin/sh
# validate-boot.sh <vm-name>
# Boots a Tart image and runs basic post-boot checks.
# Exits 0 on success; non-zero with a one-line reason on failure.

set -eu
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$REPO_ROOT/scripts/tart-helpers.sh"

VM=${1:-}
[ -z "$VM" ] && { echo "usage: $0 <vm-name>" >&2; exit 1; }

echo "[validate] starting $VM"
tart run --no-graphics "$VM" >/dev/null 2>&1 &
TART_PID=$!
trap 'tart stop "$VM" >/dev/null 2>&1 || true; kill $TART_PID 2>/dev/null || true' EXIT

echo "[validate] waiting for ssh"
if ! tart_wait_ssh "$VM" root; then
  echo "FAIL: ssh did not become available within 120s"
  exit 1
fi

echo "[validate] running smoke checks"
tart_ssh "$VM" root sh -c '
  set -e
  echo "uname: $(uname -a)"
  echo "uptime: $(uptime)"
  # Phase 2 minimum criteria: sshd + default route. dbus + elogind are
  # deferred to a later phase (need Python/meson bootstrap); they get
  # a warning if absent but do not fail the smoke test.
  pidof sshd         >/dev/null || { echo "FAIL: sshd not running"; exit 4; }
  ip route get 1.1.1.1 >/dev/null 2>&1 || { echo "FAIL: no default route"; exit 5; }
  pidof dbus-daemon  >/dev/null || echo "WARN: dbus not running (deferred)"
  pidof elogind      >/dev/null || echo "WARN: elogind not running (deferred)"
  echo "[validate] PASS"
'
