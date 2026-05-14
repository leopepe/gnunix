#!/bin/bash
# tools/bootstrap-builder.sh
# Phase 1: produce the gnunix-builder:base Tart snapshot used by Phase 2.
#
# Equivalent to Steps 1+2 of docs/runbooks/build.md, scripted for any
# host shell (fish, bash, zsh — invoke as a command, no sourcing required).
#
# Idempotent: re-running is safe. Skips work already done.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$REPO_ROOT/scripts/tart-helpers.sh"

UBUNTU_IMAGE=${UBUNTU_IMAGE:-ghcr.io/cirruslabs/ubuntu:latest}
BUILDER=${BUILDER:-gnunix-builder}
BUILDER_SNAPSHOT=${BUILDER_SNAPSHOT:-gnunix-builder:base}
DISK_SIZE=${DISK_SIZE:-60}

if tart_exists "$BUILDER_SNAPSHOT"; then
  echo "[bootstrap] $BUILDER_SNAPSHOT already exists — nothing to do."
  echo "            Delete it with 'tart delete $BUILDER_SNAPSHOT' to force a rebuild."
  exit 0
fi

echo "[bootstrap] pulling $UBUNTU_IMAGE"
tart pull "$UBUNTU_IMAGE"

if ! tart_exists "$BUILDER"; then
  echo "[bootstrap] cloning $UBUNTU_IMAGE → $BUILDER (disk=${DISK_SIZE}G)"
  tart clone "$UBUNTU_IMAGE" "$BUILDER"
  tart set "$BUILDER" --disk-size "$DISK_SIZE"
fi

WE_STARTED_VM=0
if ! tart_running "$BUILDER"; then
  echo "[bootstrap] starting $BUILDER"
  tart run --no-graphics "$BUILDER" >/dev/null 2>&1 &
  WE_STARTED_VM=1
fi

cleanup() {
  if [ "$WE_STARTED_VM" = "1" ]; then
    tart stop "$BUILDER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "[bootstrap] waiting for ssh on $BUILDER"
tart_wait_ssh "$BUILDER" admin || { echo "[bootstrap] ssh never came up"; exit 1; }

BUILDER_IP=$(tart_ip "$BUILDER")
echo "[bootstrap] running provision.sh on $BUILDER ($BUILDER_IP)"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
# shellcheck disable=SC2086
scp $SSH_OPTS "$REPO_ROOT/images/gnunix-builder/provision.sh" "admin@$BUILDER_IP:/tmp/"
# shellcheck disable=SC2086
ssh $SSH_OPTS "admin@$BUILDER_IP" "sudo bash /tmp/provision.sh"

# Install host's SSH public key into admin@ so subsequent build runs are
# passwordless. -f forces copy (avoids re-prompt if the key is already there).
# Falls back gracefully if no host key exists.
HOST_KEY=""
for cand in ~/.ssh/id_ed25519.pub ~/.ssh/id_ecdsa.pub ~/.ssh/id_rsa.pub; do
  [ -f "$cand" ] && { HOST_KEY=$cand; break; }
done
if [ -n "$HOST_KEY" ]; then
  echo "[bootstrap] installing $HOST_KEY into admin@$BUILDER (one password prompt)"
  # shellcheck disable=SC2086
  ssh-copy-id -f -i "$HOST_KEY" $SSH_OPTS "admin@$BUILDER_IP" || \
    echo "[bootstrap] WARN: ssh-copy-id failed; future runs will keep prompting for 'admin'"
else
  echo "[bootstrap] WARN: no host SSH key found (~/.ssh/id_*.pub); skipping key install"
fi

echo "[bootstrap] sync + stopping $BUILDER for snapshot"
# CRITICAL: cirruslabs Ubuntu image mounts / with commit=30. Writes made
# within ~30s of 'tart stop' can be lost — the SSH key install, package
# state, /etc/ modifications all disappear on the next boot. Force sync.
# shellcheck disable=SC2086
ssh $SSH_OPTS "admin@$BUILDER_IP" "sudo sync; sync" || true
tart stop "$BUILDER" 2>/dev/null || true
WE_STARTED_VM=0
trap - EXIT

echo "[bootstrap] snapshotting $BUILDER → $BUILDER_SNAPSHOT"
tart clone "$BUILDER" "$BUILDER_SNAPSHOT"

echo "[bootstrap] done. $BUILDER_SNAPSHOT is ready — run tools/build-all.sh gnunix-base."
