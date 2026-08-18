# hadolint global ignore=DL3008

# bootc is not packaged in Ubuntu, so build it from a release tag. Everything
# else it needs (ostree, composefs, dracut, systemd-boot) comes from the archive.
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


FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# bootc requires dracut, so keep initramfs-tools out.
COPY <<EOF /etc/apt/preferences.d/no-initramfs-tools
Package: initramfs-tools*
Pin: release *
Pin-Priority: -1
EOF

# Staged before the kernel so /usr/lib/kernel/install.conf is in place and
# kernel-install defers to bootc instead of generating an initramfs itself. The
# rest of rootfs/ lands after apt: its tmpfiles.d rules retarget /var/lib/dpkg
# and /etc/resolv.conf, which breaks dpkg if applied by a postinst mid-install.
COPY rootfs/usr/lib/kernel/ /usr/lib/kernel/

# The stock signed kernel is used as-is: it already carries FS_VERITY=y and
# EROFS_FS=m, which the composefs backend needs at boot.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install --no-install-recommends -y \
    composefs \
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
    systemd-resolved \
    systemd-timesyncd \
    ubuntu-minimal \
    zstd

COPY rootfs/ /

# Installed after the packages so it links against the archive's libostree, and
# before dracut so the 51bootc dracut module is available.
COPY --from=bootc-builder /out/usr/ /usr/
RUN ldconfig

# Generate the initramfs and stage vmlinuz next to the modules for ostree/bootc.
RUN kver="$(basename "$(echo /usr/lib/modules/*)")"; \
    depmod "${kver}"; \
    dracut --force --no-hostonly --reproducible --zstd --verbose \
      --kver "${kver}" "/usr/lib/modules/${kver}/initramfs.img"; \
    cp "/boot/vmlinuz-${kver}" "/usr/lib/modules/${kver}/vmlinuz"

# The base image ships an 'ubuntu' user; a base image should carry no login
# accounts, so drop it and let a derived image create the primary user. Its home
# directory goes away with /home in the layout step below.
RUN userdel ubuntu

# Make the filesystem layout ostree-compatible. Remove the placeholder fstab too,
# or bootc's /etc overlay makes libmount warn "fstab has been modified" at boot.
# hadolint ignore=SC2114
RUN rm -rf /boot /srv /home /root /usr/local /mnt && \
    mkdir -p /boot /sysroot /var && \
    ln -s /var/home /home && \
    ln -s /var/roothome /root && \
    ln -s /var/srv /srv && \
    ln -s /var/usrlocal /usr/local && \
    ln -s /var/mnt /mnt && \
    ln -s sysroot/ostree /ostree && \
    rm -f /etc/fstab

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

# Relocate the dpkg database to /usr so it persists across image updates (/var is
# only applied at first provisioning). A tmpfiles.d symlink restores /var/lib/dpkg.
RUN mkdir -p /usr/lib/sysimage && \
    mv /var/lib/dpkg /usr/lib/sysimage/dpkg

# bootc expects /var empty (populated at boot via tmpfiles.d) and /run, /tmp clean.
RUN rm -rf /run/* /tmp/* /var/log/* && \
    find /var -mindepth 1 -type f -delete && \
    find /var -mindepth 1 -type l -delete && \
    find /var -mindepth 1 -type d -empty -delete

LABEL containers.bootc=1

RUN bootc container lint --fatal-warnings
