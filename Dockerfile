# hadolint global ignore=DL3008,DL3059

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


FROM ubuntu:26.04 AS ignition-builder

ENV DEBIAN_FRONTEND=noninteractive

ARG IGNITION_REPO=https://github.com/coreos/ignition.git
ARG IGNITION_VERSION=v2.26.0

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install --no-install-recommends -y \
    ca-certificates \
    gcc \
    git \
    golang-go \
    libblkid-dev \
    libc6-dev \
    pkg-config

WORKDIR /ignition
# Ubuntu packages Ignition, but 2.14.0 is four years old (config spec 3.3.0 at
# best), its dracut module hand-rolls the unit symlinks in a way that leaves
# them all dangling, and it is built with the upstream defaults for two flags
# that are wrong here:
#
#   selinuxRelabel              Ubuntu has no /etc/selinux/config, so the files
#                               stage fails after writing everything.
#   writeAuthorizedKeysFragment Puts keys in .ssh/authorized_keys.d/ignition,
#                               which only Fedora CoreOS reads (via an sshd
#                               AuthorizedKeysCommand). Ubuntu's sshd wants
#                               .ssh/authorized_keys.
# Invoking go build directly rather than ./build: that script appends its own
# -X flag to $GLDFLAGS without a separating space, so anything passed in gets
# concatenated onto the next flag and the linker rejects the result.
ENV DISTRO=github.com/coreos/ignition/v2/internal/distro
RUN --mount=type=cache,target=/root/.cache/go-build,sharing=locked \
    git init && \
    git remote add origin "${IGNITION_REPO}" && \
    git fetch --depth 1 origin "${IGNITION_VERSION}" && \
    git checkout FETCH_HEAD && \
    GOFLAGS=-mod=vendor CGO_ENABLED=1 go build -buildmode=pie \
      -ldflags "-s -w \
        -X github.com/coreos/ignition/v2/internal/version.Raw=${IGNITION_VERSION} \
        -X ${DISTRO}.selinuxRelabel=false \
        -X ${DISTRO}.writeAuthorizedKeysFragment=false" \
      -o /out/usr/lib/dracut/modules.d/30ignition/ignition \
      github.com/coreos/ignition/v2/internal && \
    GOFLAGS=-mod=vendor CGO_ENABLED=0 go build \
      -ldflags "-s -w -X github.com/coreos/ignition/v2/internal/version.Raw=${IGNITION_VERSION}" \
      -o /out/usr/bin/ignition-validate \
      github.com/coreos/ignition/v2/validate && \
    cp -r dracut/30ignition/. /out/usr/lib/dracut/modules.d/30ignition/ && \
    ln -s ../lib/dracut/modules.d/30ignition/ignition /out/usr/bin/ignition


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
    curl \
    dmsetup \
    dosfstools \
    dracut \
    dracut-network \
    e2fsprogs \
    efibootmgr \
    fdisk \
    gdisk \
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
    ubuntu-minimal \
    zstd

# Must land after apt: these tmpfiles.d rules retarget /var/lib/dpkg, which
# destroys the dpkg database if a postinst applies them mid-install.
COPY rootfs/ /

# Installed after the packages so it links against the archive's libostree, and
# before dracut so the 51bootc dracut module is available.
COPY --from=bootc-builder /out/usr/ /usr/
# Same reason: the 30ignition dracut module has to exist before the initramfs is
# generated. The binary lives inside the module directory, where its
# module-setup.sh expects distro packaging to put it.
COPY --from=ignition-builder /out/usr/ /usr/
RUN ldconfig

# Generate the initramfs and stage vmlinuz next to the modules for ostree/bootc.
RUN kver="$(basename "$(echo /usr/lib/modules/*)")"; \
    depmod "${kver}"; \
    dracut --force --no-hostonly --reproducible --zstd --verbose \
      --kver "${kver}" "/usr/lib/modules/${kver}/initramfs.img"; \
    cp "/boot/vmlinuz-${kver}" "/usr/lib/modules/${kver}/vmlinuz"

# Drop the 'ubuntu' user shipped by the base image. A derived image creates the
# primary user. Its home directory goes away with /home in the layout step below.
RUN userdel ubuntu

# Make the filesystem layout ostree-compatible. The symlinks are relative, as
# ostree's own layout has them: an absolute /home -> /var/home escapes the tree
# when a tool walks the deployment from outside it, such as Ignition writing to
# /sysroot from the initramfs. Remove the placeholder fstab too, or bootc's /etc
# overlay makes libmount warn "fstab has been modified" at boot.
# hadolint ignore=SC2114
RUN rm -rf /boot /srv /home /root /usr/local /mnt && \
    mkdir -p /boot /sysroot /var && \
    ln -s var/home /home && \
    ln -s var/roothome /root && \
    ln -s var/srv /srv && \
    ln -s ../var/usrlocal /usr/local && \
    ln -s var/mnt /mnt && \
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

# Make systemd generate a real machine ID on first boot. Otherwise every installed
# machine shares the same one.
RUN : > /etc/machine-id

# Let sshd-keygen generate unique per-machine host keys on first boot. Delete the
# keys openssh-server's postinstall hook generates at build time.
RUN rm -f /etc/ssh/ssh_host_*

# bootc expects /var empty (populated at boot via tmpfiles.d) and /run, /tmp clean.
RUN rm -rf /run/* /tmp/* /var/log/* && \
    find /var -mindepth 1 -type f -delete && \
    find /var -mindepth 1 -type l -delete && \
    find /var -mindepth 1 -type d -empty -delete

LABEL containers.bootc=1

RUN bootc container lint --fatal-warnings
