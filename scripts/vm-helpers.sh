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
    # Linux/CI path: qemu-system-aarch64 under TCG.
    #
    # NOT KVM. ADR-016 and ADR-021 both say "qemu+KVM", but GitHub's
    # ubuntu-22.04-arm runners expose no /dev/kvm (probed 2026-09-12),
    # so the only available accelerator is TCG. Emulation is roughly an
    # order of magnitude slower than native, which is why the SSH wait
    # below is minutes rather than seconds.
    #
    # Boot method: the gnunix-base artifact is a GPT disk with an EFI
    # system partition and GRUB in it (ADR-006), so it boots the way real
    # hardware would — through UEFI firmware (AAVMF/edk2) on pflash.
    # An earlier version tried to locate a kernel inside the image and
    # pass -kernel; that could not work (it ran `find` against unmounted
    # block devices, and `losetup --parted` is not a flag), and it also
    # bypassed the bootloader the image exists to exercise.
    #
    # Networking: qemu user-mode, guest :22 forwarded to $VM_SSH_PORT.
    # Console: captured to <vmdir>/console.log — the only diagnostic
    # available when a guest fails to come up.

    _VM_BASE_DIR="${REPO_ROOT:-.}/cache/vms"
    : "${VM_SSH_PORT:=2222}"
    : "${VM_SSH_KEY:=}"
    : "${VM_SSH_TIMEOUT:=600}"
    : "${VM_EFI_CODE:=/usr/share/AAVMF/AAVMF_CODE.fd}"
    : "${VM_EFI_VARS:=/usr/share/AAVMF/AAVMF_VARS.fd}"
    : "${VM_MEM_MB:=2048}"
    # Referenced unquoted in the qemu argv below for deliberate word
    # splitting. Without a default, `set -u` kills the launch subshell
    # before qemu ever execs — which is exactly what run 34719707628 hit.
    : "${QEMU_EXTRA_ARGS:=}"

    _vm_ssh_opts() {
      printf '%s' "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
      [ -n "$VM_SSH_KEY" ] && printf ' %s' "-i $VM_SSH_KEY -o IdentitiesOnly=yes"
    }

    # vm_import_raw <raw-image> <vm-name>
    # Take a raw disk image and set up a VM directory around a private
    # copy of it, so the caller's artifact is never mutated by a boot.
    vm_import_raw() {
      local img=$1 vm=$2
      local vmdir="$_VM_BASE_DIR/$vm"
      [ -f "$img" ] || { echo "[vm-qemu] no such image: $img" >&2; return 1; }
      mkdir -p "$vmdir"
      echo "[vm-qemu] importing $(basename "$img") -> $vmdir/disk.img"
      cp "$img" "$vmdir/disk.img"
      # Each VM needs its own writable copy of the EFI variable store.
      [ -f "$VM_EFI_VARS" ] || {
        echo "[vm-qemu] EFI vars template not found: $VM_EFI_VARS" >&2
        echo "          install qemu-efi-aarch64 (provides /usr/share/AAVMF)" >&2
        return 1
      }
      cp "$VM_EFI_VARS" "$vmdir/efi-vars.fd"
    }

    vm_console_path() { printf '%s\n' "$_VM_BASE_DIR/$1/console.log"; }

    _qemu_start() {
      local vm=$1 detach=${2:-0}
      # Drop the two arguments we consumed. Whatever is left is passed
      # through to qemu verbatim -- without this shift, the VM name and
      # the detach flag land on qemu's argv as bare disk images:
      #   qemu-system-aarch64: <vm>: drive with bus=0, unit=0 exists
      if [ $# -ge 2 ]; then shift 2; else shift $#; fi
      local vmdir="$_VM_BASE_DIR/$vm"
      local disk="$vmdir/disk.img"
      local pidf="$vmdir/qemu.pid"

      [ -f "$disk" ] || { echo "[vm-qemu] $disk not found (run vm_import_raw first)" >&2; return 1; }
      [ -f "$VM_EFI_CODE" ] || { echo "[vm-qemu] EFI firmware not found: $VM_EFI_CODE" >&2; return 1; }

      echo "[vm-qemu] starting $vm (disk=$disk, tcg, ssh on :$VM_SSH_PORT)"
      echo "[vm-qemu] console -> $vmdir/console.log"

      # Create both logs up front. If qemu dies before it execs, these stay
      # empty rather than absent, and CI's artifact upload still has files
      # to collect -- "no files found" is a worse diagnostic than "empty".
      : > "$vmdir/console.log"
      : > "$vmdir/qemu.log"

      (
        cd "$vmdir" || exit
        qemu-system-aarch64 \
          -M virt \
          -accel tcg \
          -cpu cortex-a72 \
          -smp 2 \
          -m "$VM_MEM_MB" \
          -drive "if=pflash,format=raw,unit=0,readonly=on,file=$VM_EFI_CODE" \
          -drive "if=pflash,format=raw,unit=1,file=$vmdir/efi-vars.fd" \
          -drive "file=$disk,if=virtio,format=raw" \
          -nic "user,model=virtio-net-pci,hostfwd=tcp::$VM_SSH_PORT-:22" \
          -display none \
          -serial "file:$vmdir/console.log" \
          -monitor none \
          -no-reboot \
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

    vm_exists()  { [ -f "$_VM_BASE_DIR/$1/disk.img" ]; }

    vm_running() {
      local pidf="$_VM_BASE_DIR/$1/qemu.pid"
      [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null
    }

    # qemu user-mode networking: the guest is always reachable on the
    # forwarded localhost port, so there is no per-VM IP to discover.
    vm_ip() { printf '127.0.0.1\n'; }

    vm_ssh() {
      local vm=$1 user=$2; shift 2
      # shellcheck disable=SC2046  # word splitting of the opt list is intended
      ssh $(_vm_ssh_opts) -p "$VM_SSH_PORT" "$user@127.0.0.1" "$@"
    }

    vm_wait_ssh() {
      local vm=$1 user=$2
      local vmdir="$_VM_BASE_DIR/$vm"
      local waited=0 step=5
      while [ "$waited" -lt "$VM_SSH_TIMEOUT" ]; do
        # A dead qemu will never answer; fail immediately rather than
        # burning the whole timeout on a guest that is not running.
        if [ -f "$vmdir/qemu.pid" ] && ! kill -0 "$(cat "$vmdir/qemu.pid")" 2>/dev/null; then
          echo "[vm-qemu] qemu exited while waiting for ssh" >&2
          return 1
        fi
        # shellcheck disable=SC2046
        if ssh $(_vm_ssh_opts) -o ConnectTimeout=5 \
               -p "$VM_SSH_PORT" "$user@127.0.0.1" true 2>/dev/null; then
          echo "[vm-qemu] ssh up after ${waited}s"
          return 0
        fi
        sleep "$step"; waited=$((waited + step))
        [ $((waited % 60)) -eq 0 ] && echo "[vm-qemu] still waiting for ssh (${waited}s/${VM_SSH_TIMEOUT}s)"
      done
      return 1
    }

    vm_clone() {
      local src=$1 dst=$2
      local src_dir="$_VM_BASE_DIR/$src"
      local dst_dir="$_VM_BASE_DIR/$dst"
      mkdir -p "$dst_dir"
      [ -f "$src_dir/disk.img" ] || { echo "[vm-helpers] no disk image in $src_dir" >&2; return 1; }
      cp "$src_dir/disk.img" "$dst_dir/disk.img"
      [ -f "$src_dir/efi-vars.fd" ] && cp "$src_dir/efi-vars.fd" "$dst_dir/efi-vars.fd"
    }

    vm_run() {
      local vm=$1 detach=0
      [ "${2:-}" = "--detach" ] && detach=1
      _qemu_start "$vm" "$detach"
    }

    vm_stop() {
      local vm=$1
      local pidf="$_VM_BASE_DIR/$vm/qemu.pid"
      if [ -f "$pidf" ]; then
        local pid
        pid=$(cat "$pidf")
        if kill -0 "$pid" 2>/dev/null; then
          # shellcheck disable=SC2046
          ssh $(_vm_ssh_opts) -o ConnectTimeout=5 -p "$VM_SSH_PORT" \
              root@127.0.0.1 "sync; sync; poweroff" 2>/dev/null || true
          sleep 3
        fi
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        rm -f "$pidf"
      fi
      return 0
    }

    vm_delete() {
      local vm=$1
      vm_stop "$vm" 2>/dev/null || true
      rm -rf "${_VM_BASE_DIR:?}/$vm"
    }

    vm_disk_path() { printf '%s\n' "$_VM_BASE_DIR/$1/disk.img"; }
    vm_dir_path()  { printf '%s\n' "$_VM_BASE_DIR/$1"; }
     ;;
   *)
    echo "[vm-helpers] unknown VM_DRIVER='$VM_DRIVER' (expected: tart, qemu)" >&2
    return 1 2>/dev/null || exit 1
     ;;
esac
