# Installer runtime — what images/installer/installer/gnunix-installer shells
# out to while it is installing onto the target disk. ADR-015.
#
# Everything else that script calls (lsblk, blkid, findmnt, mkfs.ext4,
# grub-install) is already in the LFS base, so it is deliberately absent here.
pkgs:

with pkgs; [
  newt        # whiptail — the TUI itself
  gptfdisk    # sgdisk
  parted      # partprobe
  rsync       # copies the live rootfs onto the target
  dosfstools  # mkfs.vfat for the target ESP
]
