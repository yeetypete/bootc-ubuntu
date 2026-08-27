# hadolint global ignore=DL3008,DL3059

# Volume label of the live ISO.
ARG ISO_LABEL=BOOTC_UBUNTU
ARG SOURCE_DATE_EPOCH=0
ARG UBUNTU_IMAGE=docker.io/library/ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b

FROM ${UBUNTU_IMAGE} AS bootc-builder

ARG SOURCE_DATE_EPOCH
ENV DEBIAN_FRONTEND=noninteractive

ARG DESTDIR=/out
ARG BOOTC_REPO=https://github.com/bootc-dev/bootc.git
ARG BOOTC_VERSION=v1.16.10

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

# bootc's release profile keeps debug info, expecting RPM split-debuginfo
# packaging we do not have. Apply its own [profile.thin] settings manually.
ENV CARGO_PROFILE_RELEASE_DEBUG=false \
    CARGO_PROFILE_RELEASE_STRIP=true \
    CARGO_PROFILE_RELEASE_LTO=true \
    CARGO_PROFILE_RELEASE_OPT_LEVEL=s \
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1

WORKDIR /bootc

RUN git clone --depth 1 --branch "${BOOTC_VERSION}" "${BOOTC_REPO}" .

RUN --mount=type=cache,target=/root/.cargo/registry,sharing=locked \
    make bin install DESTDIR="${DESTDIR}"


FROM ${UBUNTU_IMAGE} AS base

ARG SOURCE_DATE_EPOCH
ENV DEBIAN_FRONTEND=noninteractive

# Staged before any apt install so the specified pins apply to it.
COPY rootfs/etc/apt/ /etc/apt/

# Keep package installs from generating an initramfs in /boot. The rootfs stage
# builds the real one. The kernel's postinst hook skips it when INITRD=No, and
# packages that call update-initramfs themselves are stopped by the config
# below. Both are staged before the kernel, so nothing can generate one first.
ENV INITRD=No
COPY rootfs/etc/initramfs-tools/update-initramfs.conf /etc/initramfs-tools/

# Staged before the kernel so /usr/lib/kernel/install.conf is in place and
# kernel-install defers to bootc instead of generating an initramfs itself.
COPY rootfs/usr/lib/kernel/ /usr/lib/kernel/

# The stock kernel already carries FS_VERITY=y and EROFS_FS=m, which the composefs
# backend needs at boot.
#
# Install packages which the live installer and the installed system need.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install --no-install-recommends -y \
    binutils \
    ca-certificates \
    composefs \
    cryptsetup-bin \
    dmsetup \
    dosfstools \
    dracut \
    e2fsprogs \
    efibootmgr \
    fdisk \
    less \
    linux-image-generic \
    network-manager \
    openssh-server \
    ostree \
    python3 \
    skopeo \
    systemd \
    systemd-boot \
    systemd-cryptsetup \
    systemd-repart \
    systemd-resolved \
    systemd-timesyncd \
    tpm2-tools \
    zstd

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


# Installed-system-only packages not needed for the live installer.
# NOTE: bubblewrap is only required for bcvk VM tests.
FROM base AS runtime

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install --no-install-recommends -y \
    bubblewrap \
    firmware-sof-signed \
    nftables \
    passt \
    podman \
    uidmap \
    wpasupplicant


FROM runtime AS desktop

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
# write to /var/lib/flatpak, which the rootfs stage empties, so ship the remote as
# a flatpakrepo file in /usr instead.
ADD --chmod=644 --checksum=sha256:3371dd250e61d9e1633630073fefda153cd4426f72f4afa0c3373ae2e8fea03a \
    https://dl.flathub.org/repo/flathub.flatpakrepo /usr/share/flatpak/remotes.d/flathub.flatpakrepo

COPY rootfs/usr/lib/systemd/system/flatpak-system-init.service /usr/lib/systemd/system/

# PackageKit installs debs into /usr, which is read-only. Make sure it doesn't run.
RUN systemctl enable \
    flatpak-system-init.service \
    gdm.service && \
    systemctl mask \
    packagekit-offline-update.service \
    packagekit.service && \
    rm -f /usr/share/dbus-1/system-services/org.freedesktop.PackageKit.service


FROM desktop AS rootfs

# git tracks only the executable bit, so the rest of each mode comes from the
# umask of whoever checked the tree out. Normalise before merging into /.
#
# TODO: replace with COPY --chmod=u=rwX,go=rX once Ubuntu's podman carries
# buildah 1.45, which added symbolic modes.
COPY rootfs/ /overlay/
RUN chmod -R u=rwX,go=rX /overlay && cp -a /overlay/. / && rm -rf /overlay

RUN --mount=type=bind,source=tools/configure-rootfs.sh,target=/configure-rootfs \
    /configure-rootfs

RUN --mount=type=bind,source=tools/cleanup.sh,target=/cleanup \
    --mount=type=bind,source=tools/label_components.py,target=/label-components \
    --network=none \
    /cleanup

LABEL containers.bootc=1

# Linting happens here rather than on the finished image because the stages
# below move the kernel out of the rootfs and into a UKI.
RUN bootc container lint --fatal-warnings


# Move vmlinuz and initramfs.img out of /usr/lib/modules, so that the image does
# not contain a second copy of what the UKI embeds.
FROM rootfs AS kernel-split

RUN mkdir /kernel && \
    bootc container split-kernel-and-rootfs --rootfs / --output /kernel


# Descends from kernel-split for /kernel, so a rootfs change rebuilds the UKI.
FROM kernel-split AS uki

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    mkdir -p /var/lib /var/log/apt /var/tmp && \
    ln -s /usr/lib/sysimage/dpkg /var/lib/dpkg && \
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


# The rootfs booted by the live ISO.
FROM base AS live-base

COPY rootfs/ /overlay/
RUN chmod -R u=rwX,go=rX /overlay && cp -a /overlay/. / && rm -rf /overlay

RUN --mount=type=bind,source=tools/configure-rootfs.sh,target=/configure-rootfs \
    /configure-rootfs

RUN --mount=type=bind,source=tools/cleanup.sh,target=/cleanup \
    --mount=type=bind,source=tools/label_components.py,target=/label-components \
    --network=none \
    /cleanup

LABEL containers.bootc=1

RUN bootc container lint --fatal-warnings


# Builds live.efi, the ISO's UKI (not the sealed one uki builds for installs).
# Contains a live-session cmdline and multi-user.target, since it's headless.
FROM live-base AS live-uki

ARG ISO_LABEL

RUN mkdir -p /var/tmp /var/roothome && \
    kver="$(basename "$(echo /usr/lib/modules/*)")" && \
    dracut --force --no-hostonly --reproducible --zstd --uefi \
      --add dmsquash-live --omit bootc \
      --kernel-cmdline "root=live:CDLABEL=${ISO_LABEL} rd.live.image systemd.unit=multi-user.target console=tty0 console=ttyS0,115200" \
      --kver "${kver}" /live.efi


FROM live-base AS live-rootfs

# Remove vmlinuz and initramfs.img from /usr/lib/modules so the squashed live
# rootfs doesn't duplicate what live-uki's UKI embeds.
RUN mkdir /kernel && \
    bootc container split-kernel-and-rootfs --rootfs / --output /kernel && \
    rm -rf /kernel

COPY live/overlay/ /overlay/
RUN chmod -R u=rwX,go=rX /overlay && cp -a /overlay/. / && rm -rf /overlay


FROM ${UBUNTU_IMAGE} AS iso-base

ENV DEBIAN_FRONTEND=noninteractive

ARG ISO_LABEL
ARG ISO_NAME
# Registry the installed system fetches updates from, recorded on the ISO.
ARG IMAGE_REF
ARG SOURCE_DATE_EPOCH

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install --no-install-recommends -y \
    dosfstools \
    mtools \
    squashfs-tools \
    xorriso


# Embeds the image, for a fully offline install.
FROM iso-base AS iso

# hadolint ignore=DL3022
RUN --mount=type=bind,from=live-rootfs,target=/rootfs \
    --mount=type=bind,from=live-uki,source=/live.efi,target=/live.efi \
    --mount=type=bind,source=live/build-iso.sh,target=/usr/local/bin/build-iso \
    --mount=type=bind,from=oci,source=image.oci,target=/iso/image.oci \
    build-iso "/out/${ISO_NAME}.iso"


FROM scratch AS iso-out

COPY --from=iso /out/ /


# Installs by pulling the image from its registry instead.
FROM iso-base AS iso-net

# hadolint ignore=DL3022
RUN --mount=type=bind,from=live-rootfs,target=/rootfs \
    --mount=type=bind,from=live-uki,source=/live.efi,target=/live.efi \
    --mount=type=bind,source=live/build-iso.sh,target=/usr/local/bin/build-iso \
    build-iso "/out/${ISO_NAME}.iso"


FROM scratch AS iso-net-out

COPY --from=iso-net /out/ /
