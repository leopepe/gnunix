# ISO assembly toolchain — used by images/installer/iso/mkiso.sh and
# images/installer/initramfs/build-initramfs.sh to produce the live ISO.
# Never installed on the target system.
#
# busybox is here for the initramfs only (ADR-017); the installed userland
# stays GNU.
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
