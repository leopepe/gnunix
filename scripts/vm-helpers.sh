#!/bin/sh
# scripts/vm-helpers.sh — driver-agnostic VM operations.
#
# Per ADR-016, the same build/test scripts run on two drivers:
#   - macOS dev box → Tart (Apple Virtualization.framework, native arm64)
#   - Linux CI / dev → qemu-system-aarch64 + KVM accel
#
# This file is the abstraction layer. Source it; call the `vm_*`
# functions; let it pick the underlying driver.
#
# Usage:
#   . "$REPO_ROOT/scripts/vm-helpers.sh"
#   vm_exists my-vm        # 0 if VM exists, non-zero otherwise
#   vm_clone src dst       # clone a stopped VM
#   vm_run --detach my-vm  # boot it
#   vm_ip my-vm            # print IP (waits up to 30s)
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
    vm_exists()   { tart_exists "$@"; }
    vm_running()  { tart_running "$@"; }
    vm_ip()       { tart_ip "$@"; }
    vm_ssh()      { tart_ssh "$@"; }
    vm_wait_ssh() { tart_wait_ssh "$@"; }
    vm_clone()    { tart clone "$1" "$2"; }
    vm_run()      { tart run "$@"; }
    vm_stop()     { tart stop "$1" >/dev/null 2>&1 || true; }
    vm_delete()   { tart delete "$1" >/dev/null 2>&1 || true; }
    vm_disk_path(){ printf '%s\n' "$HOME/.tart/vms/$1/disk.img"; }
    vm_dir_path() { printf '%s\n' "$HOME/.tart/vms/$1"; }
    ;;
  qemu)
    # Linux/CI path. qemu-system-aarch64 + KVM. Per-VM state lives
    # under $REPO_ROOT/cache/vms/<name>/ (disk.img + config + pid).
    #
    # NOTE: stub implementation. PR-2 introduces the abstraction;
    # PR-3 (CI release-dep flow) fills in the qemu side. Until then,
    # any vm_* call on Linux exits with a TODO marker so CI fails
    # loud rather than silently doing the wrong thing.
    _vm_todo() { echo "[vm-helpers] TODO: qemu driver — implement '$1' in PR-3 (ADR-016)" >&2; return 99; }
    vm_exists()   { _vm_todo vm_exists; }
    vm_running()  { _vm_todo vm_running; }
    vm_ip()       { _vm_todo vm_ip; }
    vm_ssh()      { _vm_todo vm_ssh; }
    vm_wait_ssh() { _vm_todo vm_wait_ssh; }
    vm_clone()    { _vm_todo vm_clone; }
    vm_run()      { _vm_todo vm_run; }
    vm_stop()     { _vm_todo vm_stop; }
    vm_delete()   { _vm_todo vm_delete; }
    vm_disk_path(){ printf '%s\n' "${REPO_ROOT:-.}/cache/vms/$1/disk.img"; }
    vm_dir_path() { printf '%s\n' "${REPO_ROOT:-.}/cache/vms/$1"; }
    ;;
  *)
    echo "[vm-helpers] unknown VM_DRIVER='$VM_DRIVER' (expected: tart, qemu)" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac
