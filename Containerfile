# hadolint global ignore=DL3008,DL3059

# Volume label of the live ISO.
ARG ISO_LABEL=BOOTC_UBUNTU

FROM ubuntu:26.04 AS bootc-builder

ENV DEBIAN_FRONTEND=noninteractive

ARG DESTDIR=/out
ARG BOOTC_REPO=https://github.com/bootc-dev/bootc.git
ARG BOOTC_VERSION=v1.16.8

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install --no-install-recommends -y \
    build-essential \
    ca-certificates \
    cargo \
    git \
    go-md2man \
    libostree-dev \
    libssl-dev \
    libzstd-dev \
    pkg-config \
    rustc

WORKDIR /bootc
RUN --mount=type=cache,target=/root/.cargo/registry,sharing=locked \
    --mount=type=cache,target=/bootc/target,sharing=locked \
    git init && \
    git remote add origin "${BOOTC_REPO}" && \
    git fetch --depth 1 origin "${BOOTC_VERSION}" && \
    git checkout FETCH_HEAD && \
    make bin install DESTDIR="${DESTDIR}"


FROM ubuntu:26.04 AS base

ENV DEBIAN_FRONTEND=noninteractive

# bootc requires dracut, so keep initramfs-tools out.
COPY <<EOF /etc/apt/preferences.d/no-initramfs-tools
Package: initramfs-tools*
Pin: release *
Pin-Priority: -1
EOF

# Staged before the kernel so /usr/lib/kernel/install.conf is in place and
# kernel-install defers to bootc instead of generating an initramfs itself.
COPY rootfs/usr/lib/kernel/ /usr/lib/kernel/

# The stock kernel already carries FS_VERITY=y and EROFS_FS=m, which the composefs
# backend needs at boot.
#
# NOTE: binutils and bubblewrap are required by bcvk VM tests only.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install --no-install-recommends -y \
    binutils \
    bubblewrap \
    composefs \
    cryptsetup-bin \
    dmsetup \
    dosfstools \
    dracut \
    e2fsprogs \
    efibootmgr \
    fdisk \
    less \
    linux-firmware \
    linux-image-generic \
    network-manager \
    openssh-server \
    ostree \
    podman \
    skopeo \
    systemd \
    systemd-boot \
    systemd-cryptsetup \
    systemd-repart \
    systemd-resolved \
    systemd-timesyncd \
    tpm2-tools \
    zstd

# Must land after apt: these tmpfiles.d rules retarget /var/lib/dpkg, which
# destroys the dpkg database if a postinst applies them mid-install.
COPY rootfs/ /

# Installed after the packages so it links against the archive's libostree, and
# before dracut so the 51bootc dracut module is available.
COPY --from=bootc-builder /out/usr/ /usr/
RUN ldconfig

# Drop the base image's 'ubuntu' user, whose home goes away with /home in the
# rootfs stage. systemd-sysusers creates the account at boot from a credential,
# and pam_mkhomedir creates its home directory.
RUN userdel ubuntu && \
    pam-auth-update --enable mkhomedir

RUN systemctl enable \
    NetworkManager.service \
    ssh.service \
    systemd-resolved.service \
    systemd-timesyncd.service \
    tmp.mount && \
    systemctl disable \
    apt-daily-upgrade.service \
    apt-daily-upgrade.timer \
    apt-daily.service \
    apt-daily.timer


FROM base AS desktop

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install --no-install-recommends -y \
    gdm3 \
    gnome-initial-setup \
    gnome-shell \
    ptyxis \
    ubuntu-minimal \
    ubuntu-session

RUN systemctl enable gdm.service


FROM desktop AS rootfs

# Generate the initramfs and stage vmlinuz next to the modules for ostree/bootc.
RUN kver="$(basename "$(echo /usr/lib/modules/*)")" && \
    depmod "${kver}" && \
    dracut --force --no-hostonly --reproducible --zstd --verbose \
      --kver "${kver}" "/usr/lib/modules/${kver}/initramfs.img" && \
    cp "/boot/vmlinuz-${kver}" "/usr/lib/modules/${kver}/vmlinuz"

# Make the filesystem layout ostree-compatible. Remove the placeholder fstab too,
# or bootc's /etc overlay makes libmount warn "fstab has been modified" at boot.
# Create /boot/EFI/Linux here because the composefs digest sealed into the UKI
# excludes the UKI but not its parent directory.
# hadolint ignore=SC2114
RUN rm -rf /boot /srv /home /root /usr/local /mnt && \
    mkdir -p /boot/EFI/Linux /sysroot /var && \
    ln -s /var/home /home && \
    ln -s /var/roothome /root && \
    ln -s /var/srv /srv && \
    ln -s /var/usrlocal /usr/local && \
    ln -s /var/mnt /mnt && \
    ln -s sysroot/ostree /ostree && \
    rm -f /etc/fstab

# Relocate the dpkg database to /usr so it persists across image updates (/var is
# only applied at first provisioning). A tmpfiles.d symlink restores /var/lib/dpkg.
RUN mkdir -p /usr/lib/sysimage && \
    mv /var/lib/dpkg /usr/lib/sysimage/dpkg

# Make systemd generate a real machine ID on first boot. Otherwise every installed
# machine shares the same one.
RUN : > /etc/machine-id

# Let sshd-keygen generate unique per-machine host keys on first boot. Delete the
# keys openssh-server's postinstall hook generates at build time.
RUN rm -f /etc/ssh/ssh_host_*

# Drop the empty /etc/resolv.conf the base image ships, so that systemd's stock
# tmpfiles rule can symlink it to the resolved stub at boot.
RUN --network=none rm -f /etc/resolv.conf

# bootc expects /var empty (populated at boot via tmpfiles.d) and /run, /tmp clean.
RUN rm -rf /run/* /tmp/* /var/log/* && \
    find /var -mindepth 1 -type f -delete && \
    find /var -mindepth 1 -type l -delete && \
    find /var -mindepth 1 -type d -empty -delete

LABEL containers.bootc=1

# Linting happens here rather than on the finished image because the stages
# below move the kernel out of the rootfs and into a UKI.
RUN bootc container lint --fatal-warnings


# Move vmlinuz and initramfs.img out of /usr/lib/modules, so that the image does
# not contain a second copy of what the UKI embeds.
FROM rootfs AS split

RUN mkdir /kernel && \
    bootc container split-kernel-and-rootfs --rootfs / --output /kernel


FROM bootc-builder AS uki

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install --no-install-recommends -y \
    systemd-boot-efi \
    systemd-ukify

RUN --mount=type=bind,from=split,target=/target \
    --mount=type=bind,from=split,source=/kernel,target=/kernel \
    kver="$(basename "$(echo /kernel/*)")" && \
    mkdir -p /uki && \
    "${DESTDIR}/usr/bin/bootc" container ukify \
      --rootfs /target --kernel-dir "/kernel/${kver}" \
      -- --output "/uki/${kver}.efi"


FROM split AS image

COPY --from=uki /uki/*.efi /boot/EFI/Linux/


# A live ISO that boots this image and installs it. Its own unified kernel image
# comes from the rootfs stage, which still has a kernel to build one from, and
# carries a command line for the live session rather than the sealed one.
FROM rootfs AS live-uki

ARG ISO_LABEL

RUN mkdir -p /var/tmp /var/roothome && \
    kver="$(basename "$(echo /usr/lib/modules/*)")" && \
    dracut --force --no-hostonly --reproducible --zstd --uefi \
      --add dmsquash-live --omit bootc \
      --kernel-cmdline "root=live:CDLABEL=${ISO_LABEL} rd.live.image systemd.unit=multi-user.target console=tty0 console=ttyS0,115200" \
      --kver "${kver}" /live.efi


FROM ubuntu:26.04 AS iso

ENV DEBIAN_FRONTEND=noninteractive

ARG ISO_LABEL
ARG ISO_NAME
# Registry the installed system fetches updates from, recorded on the ISO.
ARG IMAGE_REF

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install --no-install-recommends -y \
    dosfstools \
    mtools \
    squashfs-tools \
    xorriso

COPY --from=split / /rootfs/
# Live-only files, which exist on the ISO and never on an installed system.
COPY live/overlay/ /rootfs/
COPY --from=live-uki /live.efi /live.efi
# The image and where it updates from. An ISO installation needs no network.
# hadolint ignore=DL3022
COPY --from=oci image.oci /iso/image.oci
RUN : "${IMAGE_REF:?no registry reference to record on the ISO}" && \
    echo "${IMAGE_REF}" > /iso/image.ref

COPY live/build-iso.sh /usr/local/bin/build-iso
RUN ISO_LABEL="${ISO_LABEL}" ISO_NAME="${ISO_NAME}" build-iso


FROM scratch AS iso-out

COPY --from=iso /out/ /
