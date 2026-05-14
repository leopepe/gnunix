#!/bin/sh
# enter-vm.sh <vm-name> [command...]
# SSH into a running Tart VM. With no command, opens an interactive shell.
# With a command, pipes stdin to it.

set -eu
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$REPO_ROOT/scripts/tart-helpers.sh"

VM=${1:-}
[ -z "$VM" ] && { echo "usage: $0 <vm-name> [command...]" >&2; exit 1; }
shift || true

USER_NAME=${LFS_VM_USER:-admin}
IP=$(tart_ip "$VM") || { echo "VM $VM has no IP yet" >&2; exit 1; }

if [ $# -eq 0 ]; then
  exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$USER_NAME@$IP"
else
  exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$USER_NAME@$IP" "$@"
fi
