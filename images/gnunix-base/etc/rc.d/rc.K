#!/bin/sh
# /etc/rc.d/rc.K — single-user maintenance runlevel.
# Stops all services and drops to root shell.

set -u
echo "[rc.K] entering single-user mode"

for s in rc.nix-daemon rc.sshd rc.network rc.elogind rc.dbus; do
  if [ -x "/etc/rc.d/$s" ]; then
    "/etc/rc.d/$s" stop 2>/dev/null || true
  fi
done

echo "[rc.K] services stopped"
