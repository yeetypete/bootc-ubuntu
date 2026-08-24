# hadolint global ignore=DL3008,DL3059

# Volume label of the live ISO.
ARG ISO_LABEL=BOOTC_UBUNTU
ARG SOURCE_DATE_EPOCH=0

FROM ubuntu:26.04 AS bootc-builder

ENV DEBIAN_FRONTEND=noninteractive

ARG DESTDIR=/out
ARG BOOTC_REPO=https://github.com/bootc-dev/bootc.git
ARG BOOTC_VERSION=v1.16.9

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
    --mount=type=cache,target=/bootc/target,sharing=locked \
    make bin install DESTDIR="${DESTDIR}"


FROM ubuntu:26.04 AS base

ENV DEBIAN_FRONTEND=noninteractive

# Staged before any apt install so the specified pins apply to it.
COPY rootfs/etc/apt/ /etc/apt/

# Staged before the kernel so the trigger is disabled before any package can
# activate it.
COPY rootfs/etc/initramfs-tools/update-initramfs.conf /etc/initramfs-tools/

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
    linux-firmware \
    linux-image-generic \
    network-manager \
    nftables \
    openssh-server \
    ostree \
    passt \
    podman \
    python3 \
    skopeo \
    systemd \
    systemd-boot \
    systemd-cryptsetup \
    systemd-repart \
    systemd-resolved \
    systemd-timesyncd \
    tpm2-tools \
    uidmap \
    wpasupplicant \
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


FROM base AS desktop

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

# Label paths with the source package that owns them, so that chunkah splits the
# image into content-based layers rather than shipping one layer per build stage.
# Must run after the last package is installed and before chunkah repacks.
#
# TODO: switch to chunkah's native dpkg backend and drop this step once
# https://github.com/coreos/chunkah/issues/155 lands.
RUN --mount=type=bind,source=tools/label_components.py,target=/label-components \
    /label-components /var/lib/dpkg

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

# Let ssl-cert.service generate a unique per-machine snakeoil keypair on first
# boot. Delete the keypair ssl-cert's postinstall hook generates at build time.
RUN find /etc/ssl/certs -lname ssl-cert-snakeoil.pem -delete && \
    rm -f /etc/ssl/certs/ssl-cert-snakeoil.pem /etc/ssl/private/ssl-cert-snakeoil.key

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


# A live ISO that boots this image and installs it. Its own unified kernel image
# comes from the rootfs stage, which still has a kernel to build one from, and
# carries a command line for the live session rather than the sealed one. It
# boots multi-user.target rather than the image's default, because the ISO
# installer is only meant to run headless.
FROM rootfs AS live-uki

ARG ISO_LABEL

RUN mkdir -p /var/tmp /var/roothome && \
    kver="$(basename "$(echo /usr/lib/modules/*)")" && \
    dracut --force --no-hostonly --reproducible --zstd --uefi \
      --add dmsquash-live --omit bootc \
      --kernel-cmdline "root=live:CDLABEL=${ISO_LABEL} rd.live.image systemd.unit=multi-user.target console=tty0 console=ttyS0,115200" \
      --kver "${kver}" /live.efi


FROM kernel-split AS live-rootfs

COPY live/overlay/ /overlay/
RUN chmod -R u=rwX,go=rX /overlay && cp -a /overlay/. / && rm -rf /overlay


FROM ubuntu:26.04 AS iso

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

# hadolint ignore=DL3022
RUN --mount=type=bind,from=live-rootfs,target=/rootfs \
    --mount=type=bind,from=live-uki,source=/live.efi,target=/live.efi \
    --mount=type=bind,source=live/build-iso.sh,target=/usr/local/bin/build-iso \
    --mount=type=bind,from=oci,source=image.oci,target=/iso/image.oci \
    build-iso "/out/${ISO_NAME}.iso"


FROM scratch AS iso-out

COPY --from=iso /out/ /
