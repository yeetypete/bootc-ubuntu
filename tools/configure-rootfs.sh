#!/bin/bash
# Build the initramfs and lay out an ostree-style directory structure, the
# way bootc, dracut and composefs expect.
set -euo pipefail

kver="$(basename "$(echo /usr/lib/modules/*)")"
depmod "${kver}"
dracut --force --no-hostonly --reproducible --zstd --verbose \
    --kver "${kver}" "/usr/lib/modules/${kver}/initramfs.img"
cp "/boot/vmlinuz-${kver}" "/usr/lib/modules/${kver}/vmlinuz"

# Remove the placeholder fstab too, or bootc's /etc overlay makes libmount
# warn "fstab has been modified" at boot. Create /boot/EFI/Linux here because
# the composefs digest sealed into the UKI excludes the UKI but not its
# parent directory.
# shellcheck disable=SC2114
rm -rf /boot /srv /home /root /usr/local /mnt
mkdir -p /boot/EFI/Linux /sysroot /var
ln -s /var/home /home
ln -s /var/roothome /root
ln -s /var/srv /srv
ln -s /var/usrlocal /usr/local
ln -s /var/mnt /mnt
ln -s sysroot/ostree /ostree
rm -f /etc/fstab
