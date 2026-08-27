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
rm -rf /boot /srv /home /root /mnt
mkdir -p /boot/EFI/Linux /sysroot /var
ln -s /var/home /home
ln -s /var/roothome /root
ln -s /var/srv /srv
ln -s /var/mnt /mnt
ln -s sysroot/ostree /ostree
rm -f /etc/fstab

# Keep the font cache in /usr so it is included in the image.
if command -v fc-cache >/dev/null; then # absent outside the desktop stage
    # Fail the build if fontconfig ever ships a different default.
    grep -q '<cachedir>/var/cache/fontconfig<' /etc/fonts/fonts.conf
    sed -i 's|<cachedir>/var/cache/fontconfig<|<cachedir>/usr/lib/fontconfig/cache<|' \
        /etc/fonts/fonts.conf
    fc-cache --system-only --force
fi
