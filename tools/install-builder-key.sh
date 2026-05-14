#!/bin/bash
# tools/install-builder-key.sh [<vm>]
# Install host's SSH public key into admin@<vm>, then refresh the <vm>:base
# snapshot (if one exists) so future 'tart clone' instances inherit it.
#
# Unattended: drives ssh-copy-id through expect with the cirruslabs Ubuntu
# image's documented default password (admin/admin). Override with
# BUILDER_PASSWORD=... if you changed it.
#
# Default vm = gnunix-builder. Snapshot name = ${vm}:base (skipped if absent).

set -euo pipefail

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$REPO_ROOT/scripts/tart-helpers.sh"

VM=${1:-gnunix-builder}
SNAPSHOT=${SNAPSHOT:-${VM}:base}
BUILDER_USER=${BUILDER_USER:-admin}
BUILDER_PASSWORD=${BUILDER_PASSWORD:-admin}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

command -v expect >/dev/null || { echo "expect not found (preinstalled on macOS)"; exit 1; }

HOST_KEY=""
for cand in ~/.ssh/id_ed25519.pub ~/.ssh/id_ecdsa.pub ~/.ssh/id_rsa.pub; do
  [ -f "$cand" ] && { HOST_KEY=$cand; break; }
done
[ -n "$HOST_KEY" ] || { echo "no ~/.ssh/id_*.pub found"; exit 1; }
echo "[install-key] using $HOST_KEY → $BUILDER_USER@$VM"

if ! tart_exists "$VM"; then
  if tart_exists "$SNAPSHOT"; then
    echo "[install-key] $VM absent; cloning $SNAPSHOT → $VM"
    tart clone "$SNAPSHOT" "$VM"
  else
    echo "[install-key] neither $VM nor $SNAPSHOT exists — run bootstrap-builder.sh first"
    exit 1
  fi
fi

WE_STARTED_VM=0
if ! tart_running "$VM"; then
  echo "[install-key] starting $VM"
  tart run --no-graphics "$VM" >/dev/null 2>&1 &
  WE_STARTED_VM=1
fi
cleanup() {
  [ "$WE_STARTED_VM" = "1" ] && tart stop "$VM" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Wait for an IP from tart, then for sshd to answer.
# ssh-keyscan probes port 22 without needing credentials, so this works
# before the host key is installed.
IP=$(tart_ip "$VM") || { echo "[install-key] never got IP for $VM"; exit 1; }
echo "[install-key] waiting for sshd at $IP"
i=0
while [ $i -lt 60 ]; do
  if ssh-keyscan -T 2 -p 22 "$IP" 2>/dev/null | grep -q '^'; then break; fi
  sleep 2; i=$((i + 1))
done
[ $i -lt 60 ] || { echo "[install-key] sshd never came up"; exit 1; }

# Drive ssh-copy-id through expect.
echo "[install-key] copying key (unattended)"
SSH_OPTS_FOR_EXPECT="$SSH_OPTS"
HOST_KEY="$HOST_KEY" \
BUILDER_USER="$BUILDER_USER" \
BUILDER_PASSWORD="$BUILDER_PASSWORD" \
IP="$IP" \
SSH_OPTS="$SSH_OPTS_FOR_EXPECT" \
expect <<'EOF'
set timeout 60
set host_key  $env(HOST_KEY)
set user      $env(BUILDER_USER)
set password  $env(BUILDER_PASSWORD)
set ip        $env(IP)
set ssh_opts  $env(SSH_OPTS)

spawn /bin/sh -c "ssh-copy-id -f -i $host_key $ssh_opts $user@$ip"
expect {
  -re "(?i)password:" { send "$password\r"; exp_continue }
  -re "Number of key.* added" { }
  eof { }
  timeout { puts "TIMEOUT waiting for ssh-copy-id"; exit 1 }
}
catch wait result
exit [lindex $result 3]
EOF

# Verify with BatchMode (no fallback to password).
# shellcheck disable=SC2086
if ssh -o BatchMode=yes $SSH_OPTS "$BUILDER_USER@$IP" true; then
  echo "[install-key] verified: key-based SSH works to $VM"
else
  echo "[install-key] WARN: ssh-copy-id reported success but BatchMode probe failed"
  exit 1
fi

echo "[install-key] sync + stopping $VM"
# CRITICAL: the cirruslabs Ubuntu image mounts / with commit=30, so writes
# made within ~30s of 'tart stop' can be lost across the next boot. Force a
# sync from inside the VM before we issue the stop.
# shellcheck disable=SC2086
ssh -o BatchMode=yes $SSH_OPTS "$BUILDER_USER@$IP" "sudo sync; sync" || true
tart stop "$VM" 2>/dev/null || true
WE_STARTED_VM=0
trap - EXIT

if tart_exists "$SNAPSHOT"; then
  echo "[install-key] refreshing snapshot $SNAPSHOT (so clones inherit the key)"
  tart delete "$SNAPSHOT"
  tart clone "$VM" "$SNAPSHOT"
else
  echo "[install-key] no $SNAPSHOT to refresh — skipping snapshot step"
fi

echo "[install-key] done. Future ssh/scp/rsync to $VM run passwordless."
