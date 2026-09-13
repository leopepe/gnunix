#!/bin/bash
# images/gnunix-desktop/build.sh — Phase 4 orchestrator.
#
# Layers a Wayland graphical session on top of gnunix-minimal-<ver> and produces
# gnunix-desktop-<ver>. ADRs: 001 (sysvinit), 002 (elogind), 003 (multi-user Nix),
# 004 (plain Nix + home-manager), 009 (compositor + greeter + system services),
# 020 (Hyprland as reference compositor).
#
# Flow:
#    1. Verify gnunix-minimal-<ver> exists (built by Phase 3).
#    2. Clone base image, boot it, ssh in as root.
#    3. Pack the etc/ tree + installer into a tarball, scp into VM.
#    4. Run install-gnunix-desktop.sh — adds nixpkgs channel, installs
#       system services, creates the unprivileged user, installs configs.
#    5. sync, stop VM.
#    6. Promote to versioned name.
#    7. Emit raw disk image + zstd compressed artifact.
#
# Per ADR-021: --ci runs on a local disk image (no Tart).
# The image is loop-mounted, the Nix layer is built on the runner
# from the flake and its closure copied in (ADR-025), configs are
# installed, and the final image is emitted.

set -euo pipefail

CI_MODE=0
for arg in "$@"; do
  case "$arg" in
      --ci) CI_MODE=1 ;;
  esac
done

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
VER=$(jq -r .lfs_image_version "$REPO_ROOT/tools/manifest.json")
ARCH=$(jq -r '.active_arch // .target_arch' "$REPO_ROOT/tools/manifest.json")
CHANNEL=$(jq -r .nix.channel "$REPO_ROOT/tools/manifest.json")

if [ "$CI_MODE" = "1" ]; then
       # === CI mode: work on a local disk image ===
       #
       # The minimal image is a zstd-compressed artifact. We decompress
       # it, loop-mount the partitions, move the Wayland layer's closure
       # in from the runner's store, and emit the final image.

    echo "[build-desktop-ci] CI mode — installing Wayland layer on disk image"

    BASE_ART="$REPO_ROOT/cache/artifacts/gnunix-minimal-${ARCH}-${VER}.img.zst"
    [ -f "$BASE_ART" ] || { echo "[build-desktop-ci] base artifact not found: $BASE_ART" >&2; exit 1; }

    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT

    BASE_IMG="$WORK/base.img"
    echo "[build-desktop-ci] decompressing base artifact → $BASE_IMG"
    zstd -d -c "$BASE_ART" > "$BASE_IMG"

     # Mount the disk image partitions.
    LOOP=$(losetup --show -fP "$BASE_IMG") || { echo "[build-desktop-ci] losetup failed" >&2; exit 1; }

    ROOT_PART="${LOOP}p2"
    MNT="$WORK/mnt"
    mkdir -p "$MNT"

        # Unwind in reverse order: the kernel filesystems sit on top of
        # $MNT, which sits on the loop device. $WORK removal is separate
        # because it holds base.img, the artifact this stage emits.
    ci_unmount() {
      umount "$MNT/sys"     2>/dev/null || true
      umount "$MNT/proc"    2>/dev/null || true
      umount "$MNT/dev/pts" 2>/dev/null || true
      umount "$MNT/dev"     2>/dev/null || true
      umount "$MNT"         2>/dev/null || true
      losetup -d "$LOOP"    2>/dev/null || true
    }
    ci_cleanup() { ci_unmount; rm -rf "$WORK"; }
    trap 'ci_cleanup' EXIT

    mount "$ROOT_PART" "$MNT"

        # Nix no longer needs these -- its closure is built on the runner
        # and copied in. They stay for the non-Nix chroot work below:
        # groupadd/useradd want /dev/null and a writable lock on /etc, and
        # anything resolving /proc/self/exe dies without /proc.
    mount --bind /dev     "$MNT/dev"
    mount --bind /dev/pts "$MNT/dev/pts"
    mount -t proc  proc   "$MNT/proc"
    mount -t sysfs sysfs  "$MNT/sys"

     # Install the installer payload (etc/ tree) into the mounted rootfs.
    echo "[build-desktop-ci] installing /etc configs"
    for d in dbus-1/system.d elogind greetd hypr pam.d xdg/waybar rc.d udev/rules.d modules-load.d ssl/certs; do
      install -d -m 0755 "$MNT/etc/$d"
    done
    if [ -d "$REPO_ROOT/images/gnunix-desktop/etc" ]; then
      cp -a "$REPO_ROOT/images/gnunix-desktop/etc/"* "$MNT/etc/"
    fi

        # Build the system profile on the runner (native aarch64), then
        # move its closure into the image. ADR-025: no nix runs inside the
        # chroot any more, which retires the whole failure class around it
        # -- no channel to subscribe to, no pivot_root sandbox error, no
        # daemon socket to miss. The flake.lock pins nixpkgs, so $CHANNEL
        # no longer selects anything here.
    echo "[build-desktop-ci] building desktopProfile on the runner"
    OUT=$(nix build --no-link --print-out-paths "$REPO_ROOT#desktopProfile")
    echo "[build-desktop-ci] copying closure into the image: $OUT"
        # `nix copy --to <dir>` writes a local store rooted at that
        # directory, which is exactly the mounted image.
    nix copy --no-check-sigs --to "$MNT" "$OUT"

        # --set replaces the profile atomically with this derivation
        # instead of stacking generations. Two variables from the runner
        # are wrong on the other side of the chroot and must be overridden:
        # $HOME does not exist inside the image, and a NIX_REMOTE=daemon
        # inherited from the runner sends nix-env after a socket that
        # nothing is listening on in there.
    chroot "$MNT" /usr/bin/env HOME=/root NIX_REMOTE= \
        /nix/var/nix/profiles/default/bin/nix-env \
        --profile /nix/var/nix/profiles/system --set "$OUT"

        # Two views of the same profile. $SYS_HOST is what we can READ
        # here -- the closure exists in the runner's own store, which the
        # image's copy is a clone of. $SYS_IMG is what we must WRITE into
        # the image: a symlink or a config naming $MNT/... would dangle
        # the moment the image boots on its own.
    SYS_HOST="$OUT"
    SYS_IMG=/nix/var/nix/profiles/system

     # Wire up kmod symlinks.
    echo "[build-desktop-ci] wiring kmod symlinks"
    install -d -m 0755 "$MNT/sbin"
    for tool in modprobe insmod rmmod lsmod kmod; do
      if [ -x "$SYS_HOST/bin/$tool" ]; then
        ln -sfn "$SYS_IMG/bin/$tool" "$MNT/sbin/$tool"
      fi
    done

     # Convenience symlinks for dbus/elogind.
    install -d -m 0755 "$MNT/usr/local/bin"
    for tool in dbus-daemon dbus-uuidgen dbus-send loginctl; do
      if [ -x "$SYS_HOST/bin/$tool" ]; then
        ln -sfn "$SYS_IMG/bin/$tool" "$MNT/usr/local/bin/$tool"
      fi
    done

     # Create messagebus/greeter users if missing.
    echo "[build-desktop-ci] creating system users"
    for g in messagebus greeter; do
      getent group "$g" >/dev/null 2>&1 || groupadd -r "$g"
      getent passwd "$g" >/dev/null 2>&1 || useradd -r -M -N -g "$g" -d /run/dbus -s /usr/bin/false "$g"
    done
     # greeter also needs video,input groups.
    for g in video input; do
      getent group "$g" >/dev/null 2>&1 || groupadd -r "$g"
    done
    getent passwd greeter >/dev/null 2>&1 || \
      useradd -r -M -N -g greeter -d /var/empty -s /usr/bin/false \
        -G video,input greeter 2>/dev/null || true

     # Create the unprivileged login user.
        # These ran on the HOST, not in the image: there is no chroot here,
        # so groupadd/useradd edited the runner's /etc/passwd and the
        # image got nothing. `install -o user` then failed on the runner,
        # which has no such user:
        #     install: invalid user 'user'
    echo "[build-desktop-ci] creating login user"
    chroot "$MNT" /bin/bash <<'USER_EOF'
set -eu
for g in wheel video input render audio seat nixbld; do
  getent group "$g" >/dev/null 2>&1 || groupadd -r "$g"
done
getent passwd user >/dev/null 2>&1 || \
  useradd -m -u 1000 -s /bin/bash \
      -G wheel,video,input,render,audio,seat,nixbld user
passwd -d user >/dev/null 2>&1 || true
install -d -m 0755 -o user -g user /home/user/.config/hypr
USER_EOF

     # Install payload configs.
    echo "[build-desktop-ci] installing Wayland configs"
    PAYLOAD_DIR="$REPO_ROOT/images/gnunix-desktop"

     # greetd config.
    if [ -f "$PAYLOAD_DIR/etc/greetd/config.toml" ]; then
      install -m 0644 "$PAYLOAD_DIR/etc/greetd/config.toml" "$MNT/etc/greetd/config.toml"
    fi

     # hypr config.
    if [ -f "$PAYLOAD_DIR/etc/hypr/hyprland.conf" ]; then
      install -d -m 0755 "$MNT/etc/hypr"
      install -m 0644 "$PAYLOAD_DIR/etc/hypr/hyprland.conf" "$MNT/etc/hypr/hyprland.conf"
    fi

     # pam.d greetd.
    if [ -f "$PAYLOAD_DIR/etc/pam.d/greetd" ]; then
      install -m 0644 "$PAYLOAD_DIR/etc/pam.d/greetd" "$MNT/etc/pam.d/greetd"
    fi

     # waybar config.
    if [ -f "$PAYLOAD_DIR/etc/xdg/waybar/config" ]; then
      install -d -m 0755 "$MNT/etc/xdg/waybar"
      install -m 0644 "$PAYLOAD_DIR/etc/xdg/waybar/config" "$MNT/etc/xdg/waybar/config"
    fi
    if [ -f "$PAYLOAD_DIR/etc/xdg/waybar/style.css" ]; then
      install -m 0644 "$PAYLOAD_DIR/etc/xdg/waybar/style.css" "$MNT/etc/xdg/waybar/style.css"
    fi

     # hostname override.
    echo "gnunix-desktop" > "$MNT/etc/hostname"

     # nsswitch.conf.
    if [ ! -f "$MNT/etc/nsswitch.conf" ]; then
      cat > "$MNT/etc/nsswitch.conf" <<'NSS_EOF'
passwd:     files
group:      files
shadow:     files
hosts:      files dns
networks:   files
protocols:  files
services:   files
ethers:     files
rpc:        files
netgroup:   files
NSS_EOF
      chmod 0644 "$MNT/etc/nsswitch.conf"
    fi

     # machine-id.
    if [ ! -f "$MNT/etc/machine-id" ] && [ -x "$SYS_HOST/bin/dbus-uuidgen" ]; then
      install -d -m 0755 "$MNT/var/lib/dbus"
      "$SYS_HOST/bin/dbus-uuidgen" --ensure="$MNT/var/lib/dbus/machine-id"
      ln -sfn /var/lib/dbus/machine-id "$MNT/etc/machine-id"
    fi

     # dbus config rewrites.
        # Read the stock config from the runner's store, but rewrite the
        # includedir to the in-image path: this file is consumed by the
        # booted system, not by us.
    SP_SHARE="$SYS_HOST/share/dbus-1"
    SP_SHARE_IMG="$SYS_IMG/share/dbus-1"
    if [ -f "$SP_SHARE/system.conf" ]; then
      sed -E "
        s|<include[^>]*>/etc/dbus-1/system\\.conf</include>||
        s|<includedir>system\\.d</includedir>|<includedir>${SP_SHARE_IMG}/system.d</includedir>|
      " "$SP_SHARE/system.conf" > "$MNT/etc/dbus-1/system.conf"
    fi
    if [ -f "$SP_SHARE/session.conf" ]; then
      sed -E "
        s|<include[^>]*>/etc/dbus-1/session\\.conf</include>||
        s|<includedir>session\\.d</includedir>|<includedir>${SP_SHARE_IMG}/session.d</includedir>|
      " "$SP_SHARE/session.conf" > "$MNT/etc/dbus-1/session.conf"
    fi

     # Start-wayland-session.sh wrapper.
    echo "[build-desktop-ci] installing session wrapper"
    cat > "$MNT/usr/local/bin/start-wayland-session.sh" <<'WRAPPER_EOF'
#!/bin/sh
# Launches Hyprland as the logged-in user. Invoked by greetd.
LOGFILE=/var/log/wayland-session.log
exec >>"$LOGFILE" 2>&1
echo "============================================="
echo "[\$(date -Iseconds)] start-wayland-session.sh PID=\$\$ USER=\$(id -un) UID=\$(id -u)"
set -x
export XDG_RUNTIME_DIR=/run/user/\$(id -u)
mkdir -p "\$XDG_RUNTIME_DIR" 2>/dev/null || true
chmod 0700 "\$XDG_RUNTIME_DIR" 2>/dev/null || true
ls -la "\$XDG_RUNTIME_DIR" || true
export PATH="/nix/var/nix/profiles/system/bin:/nix/var/nix/profiles/default/bin:\$PATH"
export XKB_DEFAULT_LAYOUT=us
export __EGL_VENDOR_LIBRARY_DIRS="/nix/var/nix/profiles/system/share/glvnd/egl_vendor.d"
export LIBGL_DRIVERS_PATH="/nix/var/nix/profiles/system/lib/dri"
export LD_LIBRARY_PATH="/nix/var/nix/profiles/system/lib:\${LD_LIBRARY_PATH:-}"
export WLR_NO_HARDWARE_CURSORS=1
/nix/var/nix/profiles/system/bin/loginctl 2>&1 | head -10 || true
exec /nix/var/nix/profiles/system/bin/Hyprland
WRAPPER_EOF
    chmod 0755 "$MNT/usr/local/bin/start-wayland-session.sh"
    touch "$MNT/var/log/wayland-session.log"
    chmod 0666 "$MNT/var/log/wayland-session.log"

     # PAM symlink.
    install -d -m 0755 "$MNT/lib/security"
    if [ -f "$SYS_HOST/lib/security/pam_elogind.so" ]; then
      ln -sfn "$SYS_IMG/lib/security/pam_elogind.so" "$MNT/lib/security/pam_elogind.so"
    fi

     # udev rules from elogind.
    echo "[build-desktop-ci] installing elogind udev rules"
    install -d -m 0755 "$MNT/etc/udev/rules.d"
    for r in "$SYS_HOST"/lib/udev/rules.d/7?-*.rules; do
      [ -f "$r" ] && install -m 0644 "$r" "$MNT/etc/udev/rules.d/$(basename "$r")"
    done

     # virtio module list.
    install -d -m 0755 "$MNT/etc/modules-load.d"
    if [ ! -f "$MNT/etc/modules-load.d/virtio.conf" ]; then
      cat > "$MNT/etc/modules-load.d/virtio.conf" <<'VIRTIO_EOF'
virtio-gpu
virtio_pci
virtio_blk
virtio_net
virtio_console
VIRTIO_EOF
    fi

     # Disable tty1 getty (greetd owns tty1).
    if [ -f "$MNT/etc/inittab" ]; then
      sed -i 's|^\(2:.*agetty.*tty1.*\)$|# \1    # disabled by gnunix-desktop (greetd owns tty1)|' "$MNT/etc/inittab"
      telinit q 2>/dev/null || true
    fi

     # Enable rc scripts.
    for rc in rc.dbus rc.elogind rc.greetd; do
      if [ -f "$MNT/etc/rc.d/$rc" ]; then
        chmod +x "$MNT/etc/rc.d/$rc"
      fi
    done

     # Sync + unmount. $WORK survives: base.img is the artifact emitted
     # below, so releasing the mounts and deleting the workspace are
     # separate steps.
    sync
    ci_unmount
    trap 'rm -rf "$WORK"' EXIT

     # Emit the final artifact.
    ART_DIR="$REPO_ROOT/cache/artifacts"
    mkdir -p "$ART_DIR"
    RAW_OUT="$ART_DIR/gnunix-desktop-${ARCH}-${VER}.img"
    echo "[build-desktop-ci] emitting raw disk artifact → $RAW_OUT"
    cp "$BASE_IMG" "$RAW_OUT"
    ls -lh "$RAW_OUT"

        # Compression is the workflow's "Compress + upload" step, not ours.
        # A backgrounded zstd here would race the workflow over the same
        # output path and the script would exit before it finished.

    echo "[build-desktop-ci] === gnunix-desktop $VER built (CI). ==="
    echo "  Raw disk image: $RAW_OUT"
    exit 0
fi

# === Tart path (local Mac) ===

NIX_VM="gnunix-minimal-$VER"
BUILD_VM="gnunix-desktop-build"
WAYLAND_VM="gnunix-desktop-$VER"

SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# 1. Base image must exist.
tart_exists "$NIX_VM" \
   || { echo "[build-wayland] $NIX_VM not found — run 'tools/build-all.sh gnunix-minimal' first" >&2; exit 1; }

# 2. Clone base.
echo "[build-wayland] cloning $NIX_VM → $BUILD_VM"
tart_exists "$BUILD_VM" && tart delete "$BUILD_VM" || true
tart clone "$NIX_VM" "$BUILD_VM"

# 3. Boot and wait for ssh.
echo "[build-wayland] starting $BUILD_VM"
tart run --no-graphics "$BUILD_VM" >/dev/null 2>&1 &
BUILDER_PID=$!

stop_builder() {
  local ip
  ip=$(tart_ip "$BUILD_VM" 2>/dev/null || true)
  if [ -n "$ip" ]; then
    ssh $SSH_OPTS -o ConnectTimeout=5 "root@$ip" "sync; sync" 2>/dev/null || true
  fi
  tart stop "$BUILD_VM" >/dev/null 2>&1 || true
  kill "$BUILDER_PID" 2>/dev/null || true
}
trap stop_builder EXIT

echo "[build-wayland] waiting for ssh"
IP=""
for _ in $(seq 1 60); do
  IP=$(tart_ip "$BUILD_VM" 2>/dev/null || true)
  if [ -n "$IP" ]; then
    if ssh $SSH_OPTS -o ConnectTimeout=2 "root@$IP" true 2>/dev/null; then
      break
    fi
  fi
  sleep 3
done
[ -n "$IP" ] || { echo "[build-wayland] ssh never came up"; exit 1; }
echo "[build-wayland] root@$IP ready"

# 4. Pack the etc tree + installer into a tarball and copy it over.
WAYLAND_DIR="$REPO_ROOT/images/gnunix-desktop"
PAYLOAD=$(mktemp -t wayland-payload.XXXXXX.tar.gz)
trap 'rm -f "$PAYLOAD"; stop_builder' EXIT
echo "[build-wayland] building payload tarball"
tar -C "$WAYLAND_DIR" -czf "$PAYLOAD" etc install-gnunix-desktop.sh

echo "[build-wayland] copying payload ($(du -h "$PAYLOAD" | cut -f1))"
scp $SSH_OPTS "$PAYLOAD" "root@$IP:/root/wayland-payload.tar.gz"

# 5. Install. Pipe the script over stdin (heredoc) to avoid the nested
#    single-quote-in-double-quote hell that bites `ssh ... bash -c '...'`.
echo "[build-wayland] running install-gnunix-desktop.sh inside VM (channel: $CHANNEL)"
# shellcheck disable=SC2087 # client-side expansion of $CHANNEL is intended
ssh $SSH_OPTS "root@$IP" bash <<EOF
set -euo pipefail
cd /root
rm -rf wayland-payload
mkdir wayland-payload
tar -C wayland-payload -xzf wayland-payload.tar.gz
NIXPKGS_CHANNEL=$CHANNEL bash wayland-payload/install-gnunix-desktop.sh
EOF

# 6. Sync + stop.
echo "[build-wayland] sync + stop $BUILD_VM"
ssh $SSH_OPTS "root@$IP" "sync; sync"
tart stop "$BUILD_VM"
trap 'rm -f "$PAYLOAD"' EXIT

# 7. Promote to versioned name.
echo "[build-wayland] cloning $BUILD_VM → $WAYLAND_VM"
tart_exists "$WAYLAND_VM" && tart delete "$WAYLAND_VM" || true
tart clone "$BUILD_VM" "$WAYLAND_VM"

# 8. Emit the raw disk image as a portable artifact (same pattern as Phase 3).
ART_DIR="$REPO_ROOT/cache/artifacts"
mkdir -p "$ART_DIR"
RAW_OUT="$ART_DIR/gnunix-desktop-$ARCH-$VER.img"
echo "[build-wayland] emitting raw disk artifact → $RAW_OUT"
cp "$HOME/.tart/vms/$WAYLAND_VM/disk.img" "$RAW_OUT"
ls -lh "$RAW_OUT"

if command -v zstd >/dev/null; then
  ZST_OUT="$RAW_OUT.zst"
  echo "[build-wayland] compressing → $ZST_OUT (level 10, backgrounded)"
  rm -f "$ZST_OUT"
   ( zstd -10 -f -k "$RAW_OUT" -o "$ZST_OUT" && ls -lh "$ZST_OUT" ) &
  ZSTD_PID=$!
  echo "[build-wayland]   zstd pid=$ZSTD_PID (will finish in background)"
fi

rm -f "$PAYLOAD"

# gnunix-desktop is the last layer in the standard pipeline. Wait for the
# zstd we just kicked off so this script's exit point is also the artifact's
# completion point — otherwise smoke tests + downstream packaging could
# race with the still-running compression.
if [ -n "${ZSTD_PID:-}" ]; then
  echo "[build-wayland] waiting for zstd ($ZSTD_PID) to finish before exit"
  wait "$ZSTD_PID" 2>/dev/null || true
fi

echo "[build-wayland] === gnunix-desktop $VER built. ==="
echo "  Tart VM:          $WAYLAND_VM   (tart run $WAYLAND_VM)"
echo "  Raw disk image:   $RAW_OUT"
echo "  Smoke test:     tests/desktop/wayland-session.sh $WAYLAND_VM"
