#!/bin/sh
# /etc/rc.d/rc.S — system initialization.
# Runs once at boot. Mounts virtual filesystems, sets up devices, then exits
# (control returns to init which transitions to the configured runlevel).

set -u
echo "[rc.S] starting system initialization"

# Mount kernel virtual filesystems
mount -n -t proc     proc     /proc
mount -n -t sysfs    sysfs    /sys
mount -n -t devtmpfs devtmpfs /dev || mount -n -t tmpfs tmpfs /dev
mkdir -p /dev/pts /dev/shm
mount -n -t devpts devpts /dev/pts -o gid=5,mode=620
mount -n -t tmpfs  tmpfs  /dev/shm
mount -n -t tmpfs  tmpfs  /run -o mode=755

# Hostname
[ -f /etc/hostname ] && hostname "$(cat /etc/hostname)"

# Initial keyboard map (skip if loadkeys not present)
command -v loadkeys >/dev/null && loadkeys -q us 2>/dev/null || true

# Set the system clock from RTC (UTC)
hwclock --hctosys --utc 2>/dev/null || true

# Start eudev — populates /dev based on sysfs and MODALIAS-autoloads modules
# for every present device. The module-first kernel relies on this.
if [ -x /usr/sbin/udevd ]; then
  /usr/sbin/udevd --daemon
  /usr/sbin/udevadm trigger --action=add
  /usr/sbin/udevadm settle
fi

# Explicit module loads (modules without MODALIAS, or per-platform overlays
# under /etc/modules-load.d/*.conf). No-op if the directory is empty.
[ -x /etc/rc.d/rc.modules ] && /etc/rc.d/rc.modules

# Mount remaining filesystems from /etc/fstab
mount -a -O no_netdev || true

# Random seed restore
if [ -f /var/lib/random-seed ]; then
  cat /var/lib/random-seed > /dev/urandom
fi

# Clean up /tmp
find /tmp -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

echo "[rc.S] complete"
