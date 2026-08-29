# hadolint global ignore=DL3008,DL3059

ARG SOURCE_DATE_EPOCH=0
ARG UBUNTU_IMAGE=docker.io/library/ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b
ARG BASE_IMAGE=base-rootfs

# git tracks only the executable bit, so the rest of each mode comes from the
# umask of whoever checked the tree out.
#
# TODO: replace with COPY --chmod=u=rwX,go=rX once Ubuntu's podman carries
# buildah 1.45, which added symbolic modes. 1.42 rejects them.
FROM ${UBUNTU_IMAGE} AS system-files

COPY system_files/ /system_files/
RUN chmod -R u=rwX,go=rX /system_files && \
    chmod -R go-rwx /system_files/base/usr/lib/netplan


FROM ${UBUNTU_IMAGE} AS builder

ARG SOURCE_DATE_EPOCH
ENV DEBIAN_FRONTEND=noninteractive

ARG DESTDIR=/out

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

ENV CARGO_PROFILE_RELEASE_DEBUG=false \
    CARGO_PROFILE_RELEASE_STRIP=true \
    CARGO_PROFILE_RELEASE_LTO=true \
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1


FROM builder AS bootc-builder

ARG BOOTC_REPO=https://github.com/bootc-dev/bootc.git
ARG BOOTC_VERSION=v1.16.10

ENV CARGO_PROFILE_RELEASE_OPT_LEVEL=s

WORKDIR /bootc

RUN git clone --depth 1 --branch "${BOOTC_VERSION}" "${BOOTC_REPO}" .

RUN --mount=type=cache,target=/root/.cargo/registry,sharing=locked \
    make bin install DESTDIR="${DESTDIR}"


FROM builder AS chunkah-builder

ARG CHUNKAH_REPO=https://github.com/coreos/chunkah.git
ARG CHUNKAH_VERSION=v0.6.0

WORKDIR /chunkah

RUN git clone --depth 1 --branch "${CHUNKAH_VERSION}" "${CHUNKAH_REPO}" .

RUN --mount=type=cache,target=/root/.cargo/registry,sharing=locked \
    --mount=type=cache,target=/chunkah/target,sharing=locked \
    cargo build --release && \
    install -D -m 0755 target/release/chunkah "${DESTDIR}/usr/bin/chunkah"


FROM ${UBUNTU_IMAGE} AS base

ARG SOURCE_DATE_EPOCH
ENV DEBIAN_FRONTEND=noninteractive

# Staged before any apt install so the specified pins apply to it.
COPY --from=system-files /system_files/base/etc/apt/ /etc/apt/

# Keep package installs from generating an initramfs in /boot. bootc-ubuntu-imagectl
# builds the real one. The kernel's postinst hook skips it when INITRD=No, and
# packages that call update-initramfs themselves are stopped by the config
# below. Both are staged before the kernel, so nothing can generate one first.
ENV INITRD=No
COPY --from=system-files /system_files/base/etc/initramfs-tools/ /etc/initramfs-tools/

# Staged before the kernel so the install.conf.d drop-in is in place and
# kernel-install defers to bootc instead of generating an initramfs itself.
COPY --from=system-files /system_files/base/usr/lib/kernel/ /usr/lib/kernel/

# The stock kernel already carries FS_VERITY=y and EROFS_FS=m, which the composefs
# backend needs at boot.
#
# Install the packages the system needs.
# NOTE: bubblewrap is only required for bcvk VM tests.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install --no-install-recommends -y \
    binutils \
    bubblewrap \
    ca-certificates \
    composefs \
    cryptsetup-bin \
    dmsetup \
    dosfstools \
    dracut \
    e2fsprogs \
    efibootmgr \
    fdisk \
    firmware-sof-signed \
    less \
    linux-image-generic \
    netplan.io \
    nftables \
    openssh-server \
    ostree \
    passt \
    podman \
    python3 \
    skopeo \
    sudo \
    systemd \
    systemd-boot \
    systemd-cryptsetup \
    systemd-repart \
    systemd-resolved \
    systemd-timesyncd \
    tpm2-tools \
    uidmap \
    zstd

# Installed after the packages so it links against the archive's libostree, and
# before dracut so the 51bootc dracut module is available.
COPY --from=bootc-builder /out/usr/ /usr/
COPY --from=chunkah-builder /out/usr/bin/chunkah /usr/bin/
RUN ldconfig

# Drop the base image's 'ubuntu' user, whose home goes away with /home in the
# base-rootfs stage. systemd-sysusers creates the account at boot from a credential,
# and pam_mkhomedir creates its home directory.
RUN userdel ubuntu && \
    pam-auth-update --enable mkhomedir

RUN systemctl enable \
    ssh.service \
    systemd-networkd.service \
    systemd-resolved.service \
    systemd-timesyncd.service \
    tmp.mount && \
    systemctl disable \
    apt-daily-upgrade.service \
    apt-daily-upgrade.timer \
    apt-daily.service \
    apt-daily.timer


# The base image.
FROM base AS base-rootfs

COPY --from=system-files /system_files/base/ /

LABEL containers.bootc=1
ENV container=oci
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]

RUN --network=none \
    --mount=type=tmpfs,target=/run \
    --mount=type=tmpfs,target=/tmp \
    /usr/libexec/bootc-ubuntu-imagectl finalize


# The desktop image, derived from the base image.
# hadolint ignore=DL3006
FROM ${BASE_IMAGE} AS desktop

COPY --from=system-files /system_files/desktop/ /

# NOTE: We install with recommended dependencies to get a more complete desktop experience.
# hadolint ignore=DL3015
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y \
    flatpak \
    gnome-software-plugin-flatpak \
    logrotate \
    ubuntu-desktop-minimal \
    ubuntu-minimal

# The ubuntu base image ships no generated locales.
RUN locale-gen en_US.UTF-8 && update-locale LANG=en_US.UTF-8

# Preconfigure Flathub, where applications come from. `flatpak remote-add` would
# write to /var/lib/flatpak, which `bootc-ubuntu-imagectl finalize` empties, so ship
# the remote as a flatpakrepo file in /usr instead.
ADD --chmod=644 --checksum=sha256:3371dd250e61d9e1633630073fefda153cd4426f72f4afa0c3373ae2e8fea03a \
    https://dl.flathub.org/repo/flathub.flatpakrepo /usr/share/flatpak/remotes.d/flathub.flatpakrepo

# PackageKit installs debs into /usr, which is read-only. Make sure it doesn't run.
RUN systemctl enable \
    bootc-ubuntu-flatpak-init.service \
    gdm.service && \
    systemctl mask \
    packagekit-offline-update.service \
    packagekit.service && \
    rm -f /usr/share/dbus-1/system-services/org.freedesktop.PackageKit.service

# Rebuild the initramfs for the added packages, strip build-time state and lint.
# Linting happens here rather than on the finished image because the stages
# below move the kernel out of the rootfs and into a UKI.
RUN --network=none \
    --mount=type=tmpfs,target=/run \
    --mount=type=tmpfs,target=/tmp \
    /usr/libexec/bootc-ubuntu-imagectl finalize


# Move vmlinuz and initramfs.img out of /usr/lib/modules, so that the image does
# not contain a second copy of what the UKI embeds.
FROM desktop AS kernel-split

RUN mkdir /kernel && \
    bootc container split-kernel-and-rootfs --rootfs / --output /kernel


# Descends from kernel-split for /kernel, so a rootfs change rebuilds the UKI.
FROM kernel-split AS uki

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install --no-install-recommends -y \
    systemd-ukify

# Seal against the chunked rootfs rather than this stage's own, because chunkah
# rewrites the file mtimes that the composefs digest covers.
RUN --mount=type=bind,from=chunked,target=/target \
    kver="$(basename "$(echo /kernel/*)")" && \
    mkdir -p /uki && \
    bootc container ukify \
      --rootfs /target --kernel-dir "/kernel/${kver}" \
      -- --output "/uki/${kver}.efi"


# chunked is a named build context supplied by `just build`, not an image name.
# hadolint ignore=DL3006
FROM chunked AS image

COPY --from=uki /uki/*.efi /boot/EFI/Linux/
