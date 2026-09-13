# ISO assembly toolchain — used by images/installer/iso/mkiso.sh and
# images/installer/initramfs/build-initramfs.sh to produce the live ISO.
# Never installed on the target system.
#
# busybox here is the ISO builder's own shell utilities, NOT the initramfs
# payload. The initramfs needs a statically linked busybox and realises
# `pkgsStatic.busybox` itself (see initramfs/build-initramfs.sh): plain
# busybox is dynamically linked against a glibc the initrd does not carry,
# so it would not exec. The installed userland stays GNU either way.
pkgs:

with pkgs; [
  xorriso        # the ISO9660/El Torito image
  squashfsTools  # mksquashfs for the live rootfs
  cpio           # initramfs archive
  mtools         # mcopy into the FAT ESP image
  dosfstools     # mkfs.vfat for the ESP image
  busybox
  grub2          # grub-mkimage for the EFI boot stub
]
