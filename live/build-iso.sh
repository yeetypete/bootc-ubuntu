#!/bin/bash
# Squash /rootfs into a live ISO that boots the unified kernel image /live.efi.
set -euo pipefail

label="${ISO_LABEL:?}"
name="${ISO_NAME:?}"
esp=/esp.img

echo "Squashing rootfs"
mkdir -p /iso/LiveOS /out
mksquashfs /rootfs /iso/LiveOS/squashfs.img \
    -noappend -no-progress -comp zstd

# Firmware loads the UKI directly. The ESP carries no bootloader and the ISO
# no boot entries. It has to live here rather than on the ISO filesystem because
# firmware reads it as a partition.
echo "Building ESP"
mkfs.vfat -F 32 -n "${label:0:11}" -C "$esp" $(( $(stat -c%s /live.efi) / 1024 + 32768 )) > /dev/null
mmd -i "$esp" ::/EFI ::/EFI/BOOT
mcopy -i "$esp" /live.efi ::/EFI/BOOT/BOOTX64.EFI

echo "Writing $name.iso"
xorriso -as mkisofs -R -J -V "$label" \
    -partition_offset 16 -appended_part_as_gpt \
    -append_partition 2 c12a7328-f81f-11d2-ba4b-00a0c93ec93b "$esp" \
    -e --interval:appended_partition_2:all:: -no-emul-boot \
    -iso-level 3 -o "/out/$name.iso" /iso

rm -rf /iso/LiveOS "$esp" /live.efi
