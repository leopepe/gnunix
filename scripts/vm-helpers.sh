#!/bin/bash
# scripts/vm-helpers.sh — driver-agnostic VM operations.
#
# Per ADR-021, the same build/test scripts run on two drivers:
#    - macOS dev box → Tart (Apple Virtualization.framework, native arm64)
#    - Linux CI / dev → qemu-system-aarch64 + KVM accel
#
# This file is the abstraction layer. Source it; call the `vm_*`
# functions; let it pick the underlying driver.
#
# Usage:
#    . "$REPO_ROOT/scripts/vm-helpers.sh"
#   vm_exists my-vm         # 0 if VM exists, non-zero otherwise
#   vm_clone src dst        # clone a stopped VM
#   vm_run --detach my-vm   # boot it
#   vm_ip my-vm             # print IP (waits up to 30s)
#   vm_ssh my-vm user "cmd"
#   vm_wait_ssh my-vm user # block until ssh comes up
#   vm_stop my-vm
#   vm_delete my-vm
#
# Driver selection: VM_DRIVER env var wins. Otherwise autodetects from
# `uname` (Darwin → tart, Linux → qemu). Sourcing scripts that need a
# specific driver can still set VM_DRIVER=tart or VM_DRIVER=qemu.
#
# shellcheck shell=bash

: "${VM_DRIVER:=$(uname | tr '[:upper:]' '[:lower:]' | sed 's/darwin/tart/;s/linux/qemu/')}"
export VM_DRIVER

case "$VM_DRIVER" in
  tart)
    # Delegate to the existing tart-helpers. The vm_* names map 1:1
    # to tart_* names — no behaviour change for macOS dev.
    REPO_ROOT_VM=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
    # shellcheck source=/dev/null
     . "$REPO_ROOT_VM/scripts/tart-helpers.sh"
    vm_exists()    { tart_exists "$@"; }
    vm_running()   { tart_running "$@"; }
    vm_ip()        { tart_ip "$@"; }
    vm_ssh()       { tart_ssh "$@"; }
    vm_wait_ssh() { tart_wait_ssh "$@"; }
    vm_clone()     { tart clone "$1" "$2"; }
    vm_run()       { tart run "$@"; }
    vm_stop()      { tart stop "$1" >/dev/null 2>&1 || true; }
    vm_delete()    { tart delete "$1" >/dev/null 2>&1 || true; }
    vm_disk_path(){ printf '%s\n' "$HOME/.tart/vms/$1/disk.img"; }
    vm_dir_path() { printf '%s\n' "$HOME/.tart/vms/$1"; }
     ;;
  qemu)
    # Linux/CI path. qemu-system-aarch64 + KVM. Per-VM state lives
    # under $REPO_ROOT/cache/vms/<name>/ (disk.qcow2 + config + pid).
    #
    # The QEMU path works with raw disk images (the portable artifact
    # format). Each VM gets its own qcow2 overlay backed by a shared
    # base image — clones are O(1) copy-on-write, not byte-copy.
    #
    # Networking: qemu user-mode with virtio-net. Port 22 on the guest
    # is forwarded to port 2222 on the host (-redir tcp:2222::22).
    # The vm_* functions use 127.0.0.1:2222 for all SSH.
    #
    # Disk images: qcow2 with backing-file support. The base image
    # (decompressed .img) is the read-only backing; each VM gets a
    # thin-provisioned qcow2 overlay.

    _VM_BASE_DIR="${REPO_ROOT:-.}/cache/vms"

    _qemu_img() {
      qemu-img "$@" || { echo "[vm-helpers] qemu-img failed" >&2; return 1; }
    }

    _qemu_cmd() {
      local vm=$1; shift
      printf '%s\n' "QEMU_CMD VM=$vm $*"
    }

    _qemu_start() {
      local vm=$1 detach=${2:-0}
      local vmdir="$_VM_BASE_DIR/$vm"
      local disk="$vmdir/disk.qcow2"
      local pidf="$vmdir/qemu.pid"
      local mac=""

      [ -f "$disk" ] || { echo "[vm-kernel] $disk not found" >&2; return 1; }

       # Read MAC from tart config if available; otherwise generate one.
      if [ -f "$vmdir/config.json" ]; then
        mac=$(jq -r .macAddress "$vmdir/config.json" 2>/dev/null || true)
      fi
      [ -z "$mac" ] && mac="52:54:00$(printf ':%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))"

      # Find kernel/initrd from the disk's boot partition.
      local kern="" initrd=""
      # Try loop device for the boot partition.
      local loop=""
      loop=$(losetup -f 2>/dev/null || true)
      if [ -n "$loop" ]; then
        losetup "$loop" "$disk" --parted 2>/dev/null || { echo "[vm-kernel] losetup --parted failed" >&2; return 1; }
        local boot_dev="${loop}p1"
        local root_dev="${loop}p2"
        # Check if partitions exist.
        if [ -b "$boot_dev" ]; then
          kern=$(find "$boot_dev" -maxdepth 1 -name "vmlinux-*" -o -name "Image" -o -name "bzImage" 2>/dev/null | head -1)
          initrd=$(find "$boot_dev" -maxdepth 1 -name "initrd.img-*" 2>/dev/null | head -1)
          [ -z "$kern" ] && kern=$(find "$root_dev" -maxdepth 3 -path "*/boot/vmlinux-*" -o -path "*/boot/Image" -o -path "*/boot/bzImage" 2>/dev/null | head -1)
          [ -z "$initrd" ] && initrd=$(find "$root_dev" -maxdepth 3 -path "*/boot/initrd.img-*" 2>/dev/null | head -1)
        fi
        losetup -d "$loop" 2>/dev/null || true
      fi

      # Fallback: look for kernel in the root partition.
      if [ -z "$kern" ]; then
        local loop2=""
        loop2=$(losetup -f 2>/dev/null || true)
        if [ -n "$loop2" ]; then
          losetup "$loop2" "$disk" --parted 2>/dev/null || { echo "[vm-kernel] losetup --parted failed" >&2; return 1; }
          local root_dev2="${loop2}p2"
          kern=$(find "$root_dev2" -maxdepth 3 \( -name "vmlinux-*" -o -name "Image" -o -name "bzImage" \) 2>/dev/null | head -1)
          initrd=$(find "$root_dev2" -maxdepth 3 -name "initrd.img-*" 2>/dev/null | head -1)
          losetup -d "$loop2" 2>/dev/null || true
        fi
      fi

      # Ultimate fallback: use the root partition directly as the kernel disk.
      if [ -z "$kern" ]; then
        # Use the disk itself as the kernel disk (some images embed the kernel).
        kern="$disk"
      fi

      echo "[vm-qemu] starting $vm (disk=$disk mac=$mac)"
      [ -n "$kern" ] && echo "[vm-qemu] kernel=$kern"
      [ -n "$initrd" ] && echo "[vm-qemu] initrd=$initrd"

      (
        cd "$vmdir" || exit
        qemu-system-aarch64 \
          -M virt \
          -cpu cortex-a72 \
          -m 2048 \
          -kernel "$kern" \
          -initrd "$initrd" \
          -drive "file=$disk,if=virtio,format=qcow2" \
          -nic "user,model=virtio-net,mac=$mac,hostfwd=tcp::2222-:22" \
          -nographic \
          -monitor none \
          -no-reboot \
          -append "console=ttyAMA0 root=/dev/vda2 rw loglevel=8" \
          $QEMU_EXTRA_ARGS \
          "$@" 2>"$vmdir/qemu.log" &
        echo $! > "$pidf"
      )

      if [ "$detach" = "1" ]; then
        echo "[vm-qemu] detached (pid=$(cat "$pidf"))"
      else
        wait "$(cat "$pidf")" 2>/dev/null || true
        rm -f "$pidf"
      fi
    }

    vm_exists() {
      [ -f "$_VM_BASE_DIR/$1/disk.qcow2" ]
    }

    vm_running() {
      local pidf="$_VM_BASE_DIR/$1/qemu.pid"
      [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null
    }

    vm_ip() {
       # For qemu user-mode, the VM is reachable at 127.0.0.1:2222.
       # Return a placeholder; the real "IP" is always 127.0.0.1.
       # But we need to wait for the VM to be ready.
      local vm=$1 i=0
      while [ $i -lt 30 ]; do
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
               -o ConnectTimeout=5 -o LogLevel=ERROR \
               root@127.0.0.1 -p 2222 true 2>/dev/null; then
          echo "127.0.0.1"
          return 0
        fi
        sleep 2; i=$((i + 1))
      done
      return 1
    }

    vm_ssh() {
      local vm=$1 user=$2; shift 2
      local ip="127.0.0.1"
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o LogLevel=ERROR -p 2222 "$user@$ip" "$@"
    }

    vm_wait_ssh() {
      local vm=$1 user=$2 i=0
      while [ $i -lt 60 ]; do
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
               -o ConnectTimeout=2 -o LogLevel=ERROR \
               "$user"@127.0.0.1 -p 2222 true 2>/dev/null; then
          return 0
        fi
        sleep 2; i=$((i + 1))
      done
      return 1
    }

    vm_clone() {
      local src=$1 dst=$2
      local src_dir="$_VM_BASE_DIR/$src"
      local dst_dir="$_VM_BASE_DIR/$dst"
      mkdir -p "$dst_dir"
      if [ -f "$src_dir/disk.qcow2" ]; then
         # qcow2 copy-on-write clone. O(1), no data copied.
        _qemu_img create -f qcow2 -b "$src_dir/disk.qcow2" -F qcow2 "$dst_dir/disk.qcow2"
      elif [ -f "$src_dir/disk.img" ]; then
        cp "$src_dir/disk.img" "$dst_dir/disk.qcow2"
      else
        echo "[vm-helpers] no disk image found in $src_dir" >&2
        return 1
      fi
       # Copy config files (tart config, etc.).
      if [ -f "$src_dir/config.json" ]; then
        cp "$src_dir/config.json" "$dst_dir/"
      fi
    }

    vm_run() {
      local vm=$1 detach=0
      [ "${2:-}" = "--detach" ] && detach=1
      _qemu_start "$vm" "$detach"
    }

    vm_stop() {
      local vm=$1
      local pidf="$_VM_BASE_DIR/$1/qemu.pid"
      if [ -f "$pidf" ]; then
        local pid
        pid=$(cat "$pidf")
        if kill -0 "$pid" 2>/dev/null; then
           # Try graceful shutdown via SSH first.
          ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
               -o ConnectTimeout=5 -o LogLevel=ERROR \
               root@127.0.0.1 -p 2222 "sync; sync; poweroff" 2>/dev/null || true
          sleep 3
        fi
        # Force kill if still running.
        if kill -0 "$pid" 2>/dev/null; then
          kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$pidf"
      fi
    }

    vm_delete() {
      local vm=$1
      vm_stop "$vm" 2>/dev/null || true
      local dir="$_VM_BASE_DIR/$vm"
      rm -rf "$dir"
    }

    vm_disk_path() {
      printf '%s\n' "$_VM_BASE_DIR/$1/disk.qcow2"
    }

    vm_dir_path() {
      printf '%s\n' "$_VM_BASE_DIR/$1"
    }
     ;;
   *)
    echo "[vm-helpers] unknown VM_DRIVER='$VM_DRIVER' (expected: tart, qemu)" >&2
    return 1 2>/dev/null || exit 1
     ;;
esac
