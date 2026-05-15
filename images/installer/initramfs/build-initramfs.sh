#!/bin/bash
# images/installer/initramfs/build-initramfs.sh
#
# Assembles the live-boot initramfs as a cpio.gz. Runs INSIDE the
# gnunix-installer-build VM, where it can pull busybox-static from
# nixpkgs.
#
# Per ADR-017 § "Initramfs design".
#
# Output:
#   $OUT_DIR/initrd.img   — cpio.gz, ~5 MB, contains busybox + init
#                           + minimal /etc + module files for
#                           {squashfs, overlay, iso9660, loop}.
#
# Env:
#   OUT_DIR    where to drop initrd.img (default: /tmp/initramfs-out)
#   KVER       kernel version (e.g. 6.12.20) — needed to pick the
#              right modules from /lib/modules/$KVER/
#   SCRIPT_DIR directory containing init script (default: dirname $0)

set -euo pipefail

SCRIPT_DIR=${SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}
OUT_DIR=${OUT_DIR:-/tmp/initramfs-out}
KVER=${KVER:-$(uname -r)}

# --- check prereqs ---------------------------------------------------
SP=/nix/var/nix/profiles/system
for t in cpio gzip find install; do
  command -v "$t" >/dev/null || { echo "[build-initramfs] missing tool: $t" >&2; exit 1; }
done

# Pull busybox-static into the system profile if it's not already there.
if [ ! -x "$SP/bin/busybox" ]; then
  echo "[build-initramfs] installing nixpkgs.busybox-sandbox-shell.static into $SP"
  export PATH=/nix/var/nix/profiles/default/bin:$PATH
  nix-env -p "$SP" -iA nixpkgs.busybox 2>&1 | tail -3 || \
    nix-env -p "$SP" -iA nixpkgs.busybox-sandbox-shell.static 2>&1 | tail -3
fi
[ -x "$SP/bin/busybox" ] || { echo "[build-initramfs] no busybox at $SP/bin/busybox" >&2; exit 1; }

# Modules we need to load from inside initramfs init. Per ADR-017 these
# are =m on gnunix-base's kernel.
WANTED_MODULES="loop squashfs overlay isofs"

# --- stage layout under a tempdir ------------------------------------
STAGE=$(mktemp -d -t initramfs-stage.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE"/{bin,sbin,etc,proc,sys,dev,run,tmp,mnt,root,lib/modules}
# busybox provides every command; install symlinks so PATH lookup works
install -m 0755 "$SP/bin/busybox" "$STAGE/bin/busybox"
for cmd in sh ash mount umount mkdir mkfifo modprobe insmod blkid readlink \
           sleep ls cat echo cp mv rm ln find grep awk sed switch_root \
           uname dmesg poweroff reboot; do
  ln -sf busybox "$STAGE/bin/$cmd"
done

# init script
install -m 0755 "$SCRIPT_DIR/init" "$STAGE/init"

# Minimal /etc — just enough for the init script to do its job.
cat > "$STAGE/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
EOF
cat > "$STAGE/etc/group" <<'EOF'
root:x:0:
EOF

# Copy the kernel modules we need (and their dependencies via depmod).
echo "[build-initramfs] copying kernel modules for $KVER"
MOD_SRC="/lib/modules/$KVER"
if [ ! -d "$MOD_SRC" ]; then
  echo "[build-initramfs] no modules dir at $MOD_SRC — is the kernel installed?" >&2
  exit 1
fi
mkdir -p "$STAGE/lib/modules/$KVER"
# Copy modules.* index files (needed by modprobe)
for f in modules.builtin modules.builtin.modinfo modules.order \
         modules.dep modules.dep.bin modules.alias modules.alias.bin \
         modules.symbols modules.symbols.bin modules.devname modules.softdep; do
  [ -f "$MOD_SRC/$f" ] && cp "$MOD_SRC/$f" "$STAGE/lib/modules/$KVER/" || true
done
# Copy the actual .ko files for our wanted modules + dependencies.
for mod in $WANTED_MODULES; do
  ko=$(find "$MOD_SRC" -name "${mod}.ko*" -print -quit)
  if [ -z "$ko" ]; then
    echo "[build-initramfs] WARN: module not found: $mod (live boot will fail)" >&2
    continue
  fi
  rel=${ko#$MOD_SRC/}
  install -D "$ko" "$STAGE/lib/modules/$KVER/$rel"
done
# Rebuild module dep index for the staged subset.
depmod -b "$STAGE" "$KVER" 2>/dev/null || \
  echo "[build-initramfs] WARN: depmod failed (modprobe may need explicit paths)"

# --- assemble cpio.gz ------------------------------------------------
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/initrd.img"
echo "[build-initramfs] assembling cpio.gz → $OUT"
( cd "$STAGE" && find . -print0 | cpio --null -ov --format=newc 2>/dev/null ) \
  | gzip -9 > "$OUT"

echo "[build-initramfs] $(du -h "$OUT" | cut -f1)  $OUT"
