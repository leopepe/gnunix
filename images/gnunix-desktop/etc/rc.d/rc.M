#!/bin/sh
# /etc/rc.d/rc.M — multi-user runlevel.
# Dispatcher that starts each enabled service in deterministic order,
# ending with greetd which owns the foreground TTY.
#
# Uses `local` — runs under /bin/sh which on this LFS system is bash.
# shellcheck shell=bash

set -u
echo "[rc.M] entering multi-user runlevel"

run_if_enabled() {
  local script="/etc/rc.d/$1"
  if [ -x "$script" ]; then
    echo "[rc.M] starting $1"
    "$script" start
  else
    echo "[rc.M] skipping $1 (not executable)"
  fi
}

# Order matters: dbus before elogind (login1 API); network before sshd;
# nix-daemon before greetd (the greetd session may invoke Nix-installed
# binaries); greetd last so it owns the foreground TTY.
run_if_enabled rc.dbus
run_if_enabled rc.elogind
run_if_enabled rc.network
run_if_enabled rc.sshd
run_if_enabled rc.nix-daemon
run_if_enabled rc.greetd

[ -x /etc/rc.d/rc.local ] && /etc/rc.d/rc.local

echo "[rc.M] complete"
