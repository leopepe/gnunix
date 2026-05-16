#!/bin/sh
# /etc/rc.d/rc.M — multi-user runlevel.
# Dispatcher: starts each enabled service in deterministic order.
# A service is enabled iff /etc/rc.d/rc.<name> is executable.
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

# Order matters: dbus before elogind, network before sshd, nix-daemon last.
# syslogd runs early so every later service's stderr can be captured.
run_if_enabled rc.syslogd
run_if_enabled rc.dbus
run_if_enabled rc.elogind
run_if_enabled rc.network
run_if_enabled rc.sshd
run_if_enabled rc.nix-daemon

# Local customizations (always last)
[ -x /etc/rc.d/rc.local ] && /etc/rc.d/rc.local

echo "[rc.M] complete"
