#!/bin/sh
# Shared helpers for working with Tart VMs.
# Source this from other scripts: . "$REPO_ROOT/scripts/tart-helpers.sh"

tart_exists() { tart list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$1"; }

tart_running() { tart list 2>/dev/null | awk -v n="$1" 'NR>1 && $2==n && $4=="running"' | grep -q .; }

tart_ip() {
  # Returns the VM's IP, blocking up to 30 seconds. Tries `tart ip` first,
  # which reads /var/db/dhcpd_leases. Falls back to looking up the VM's
  # configured macAddress in ARP — needed when the guest's DHCP exchange
  # doesn't leave a lease entry bootpd recognizes (e.g., gnunix-base where
  # dhcpcd's hostname/client-id confuses Apple's bootpd, but the kernel-
  # level virtio-net traffic still populates the macOS ARP cache).
  local name=$1 i=0
  while [ $i -lt 30 ]; do
    local ip; ip=$(tart ip "$name" 2>/dev/null || true)
    if [ -n "$ip" ] && [ "$ip" != "no IP address found" ]; then
      printf '%s\n' "$ip"; return 0
    fi
    # Fallback: arp -an by macAddress from VM config.json. macOS's arp strips
    # leading zeros from each MAC octet (e.g. ca:00:26 → ca:0:26), so we
    # normalize both sides before comparing.
    local cfg="$HOME/.tart/vms/$name/config.json"
    if [ -f "$cfg" ]; then
      local mac; mac=$(jq -r .macAddress "$cfg" 2>/dev/null)
      if [ -n "$mac" ]; then
        local mac_n; mac_n=$(echo "$mac" | awk -F: '{for(i=1;i<=NF;i++){sub(/^0/,"",$i)} print tolower($1":"$2":"$3":"$4":"$5":"$6)}')
        ip=$(arp -an 2>/dev/null | awk -F'[() ]+' -v m="$mac_n" '
          {
            for (i=1;i<=NF;i++) if (tolower($i) ~ /^[0-9a-f]+:[0-9a-f]+:[0-9a-f]+:[0-9a-f]+:[0-9a-f]+:[0-9a-f]+$/) {
              cand=tolower($i)
              gsub(/(^|:)0+([0-9a-f])/, "\\1\\2", cand)
              if (cand==m) { print $2; exit }
            }
          }')
        if [ -n "$ip" ]; then printf '%s\n' "$ip"; return 0; fi
      fi
    fi
    sleep 1; i=$((i + 1))
  done
  return 1
}

tart_ssh() {
  # tart_ssh <vm> <user> <command...>
  local vm=$1 user=$2; shift 2
  local ip; ip=$(tart_ip "$vm") || { echo "no IP for $vm" >&2; return 1; }
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR "$user@$ip" "$@"
}

tart_wait_ssh() {
  local vm=$1 user=$2 i=0
  local ip; ip=$(tart_ip "$vm") || return 1
  while [ $i -lt 60 ]; do
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=2 -o LogLevel=ERROR "$user@$ip" true 2>/dev/null; then
      return 0
    fi
    sleep 2; i=$((i + 1))
  done
  return 1
}
