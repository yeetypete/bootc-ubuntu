# bootc-ubuntu developer tasks.

# Image repository for the built image.
image := "yeetypete/bootc-ubuntu"
# Version for image labels and the tag suffix, without its leading "v".
version := trim_start_match("v0.0.0", "v")
# Git commit SHA for image labels.
revision := `git rev-parse HEAD 2>/dev/null || echo ""`
# Commit date, recorded as the image creation annotation.
created := `git log -1 --pretty=%cI 2>/dev/null || echo ""`
# Tag the image is built with.
tag := "26.04"
# Registry repository holding the layer cache, e.g. docker.io/yeetypete/bootc-ubuntu-cache.
cache_repo := ""

# Local OCI layout the image is exported to.
oci_dir := "image.oci"
# Registry reference of the built image, as the installed system refers to it.
imgref := "docker.io/" + image + ":" + tag
cache_args := if cache_repo == "" { "" } else { "--cache-from " + cache_repo + " --cache-to " + cache_repo }
created_args := if created == "" { "" } else { "--annotation org.opencontainers.image.created=" + created }
# Container image providing chunkah, which repacks the image into content-based
# layers so that an update ships only the packages that changed.
chunkah := "quay.io/coreos/chunkah:v0.6.0"
# Maximum number of layers chunkah packs the image into.
max_layers := "128"
# The rootfs as built, before chunking and sealing.
target := "localhost/bootc-ubuntu-target:" + tag
# The rootfs repacked into content-based layers, which the UKI is sealed against.
chunked := "localhost/bootc-ubuntu-chunked:" + tag
# Firmware for the qemu recipes. Booting this image needs UEFI.
ovmf := "-drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,unit=1,readonly=on,file=/usr/share/OVMF/OVMF_VARS_4M.fd"
# Base name of the generated disk images and ISO.
name := "bootc-ubuntu"
# Disk image `just disk` installs to, and `just boot` boots. bcvk sizes it for us.
disk_img := name + ".img"
# Live ISO built by `just live`.
iso := name + ".iso"
# Disk image the live ISO installs to, and `just boot-live` boots.
live_img := name + "-live.img"
# Account provisioned into a test VM.
user := "ubuntu"
# QEMU display for the VM recipes. "none" keeps the console on this terminal;
# set display=gtk for a window, the only way to see the desktop.
display := "none"
graphics := if display == "none" { "-nographic" } else { "-vga none -device virtio-vga-gl -display " + display + ",gl=on -serial mon:stdio" }

# List available recipes.
default:
    @just --list

# Build the bootc container image in three steps:
#
# 1. Build the rootfs.
# 2. Repack it into content-based layers.
# 3. Seal the repacked rootfs into the UKI and assemble the final image.
#
# chunkah runs before the UKI is sealed because it rewrites the file mtimes that
# the sealed composefs digest covers.
[group('image')]
build *args:
    #!/usr/bin/env bash
    set -euo pipefail
    podman build --jobs 0 --target kernel-split \
        --label org.opencontainers.image.version={{ version }} \
        --label org.opencontainers.image.revision={{ revision }} \
        --timestamp 0 \
        {{ cache_args }} \
        --tag {{ target }} \
        {{ args }} .
    # chunkah only sees the mounted filesystem, so labels and annotations have to
    # be handed to it or they are lost.
    work=$(mktemp -d -p /var/tmp)
    trap 'rm -rf "${work}"' EXIT
    config=$(podman inspect {{ target }})
    podman run --rm \
        --mount=type=image,src={{ target }},dst=/chunkah \
        -e CHUNKAH_CONFIG_STR="${config}" \
        -v "${work}:/out:z" \
        {{ chunkah }} build \
            --max-layers {{ max_layers }} \
            --source-date-epoch 0 \
            --prune /kernel \
            --tag {{ chunked }} \
            --output oci:/out/layout
    podman pull --quiet "oci:${work}/layout:{{ chunked }}"
    podman build --jobs 0 --target image \
        --timestamp 0 \
        --build-context chunked=container-image://{{ chunked }} \
        {{ cache_args }} \
        {{ created_args }} \
        --tag {{ imgref }} \
        --tag {{ imgref }}-{{ revision }} \
        {{ args }} .

# Export the bootc container image as an OCI directory.
[group('image')]
oci: build
    rm -rf {{ oci_dir }}
    podman push --quiet --compression-format zstd {{ imgref }} oci:{{ oci_dir }}:{{ tag }}

# Push the image to its registry under the commit it was built from.
[group('image')]
push: build
    podman push --compression-format zstd --force-compression {{ imgref }}-{{ revision }}

# Publish a tagged release.
[group('image')]
push-release: push
    podman tag {{ imgref }}-{{ revision }} {{ imgref }}-{{ version }}
    podman push --compression-format zstd --force-compression {{ imgref }}-{{ version }}
    podman push --compression-format zstd --force-compression {{ imgref }}

# Print the credentials that provision NAME, one name:base64 pair per line. The
# account lives only in what is passed in at boot, not the image.
[private]
credentials name=user:
    #!/usr/bin/env bash
    set -euo pipefail
    read -rsp "Password for {{ name }}: " password < /dev/tty > /dev/tty
    echo > /dev/tty
    [[ -n "$password" ]] || { echo "Password must not be empty." >&2; exit 1; }
    # Set the UID explicitly. sysusers allocates from the system range otherwise,
    # and a login below UID_MIN is hidden from the login screen.
    account=$(printf 'u %s 1000 "Ubuntu" /var/home/%s /bin/bash\nm %s sudo\n' \
        {{ name }} {{ name }} {{ name }} | base64 -w0)
    hashed=$(printf '%s' "$(openssl passwd -6 "$password")" | base64 -w0)
    printf 'sysusers.extra:%s\n' "$account"
    printf 'passwd.hashed-password.{{ name }}:%s\n' "$hashed"

# Boot IMG in qemu, with the console on this terminal.
[private]
qemu-boot img user:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ -f {{ img }} ]] || { echo "{{ img }} does not exist." >&2; exit 1; }
    creds=()
    if [[ -n "{{ user }}" ]]; then
        pairs=$(just credentials {{ user }})
        # SMBIOS separates the pair with = rather than :.
        while read -r cred; do
            creds+=(-smbios "type=11,value=io.systemd.credential.binary:${cred/:/=}")
        done <<< "$pairs"
    fi
    exec qemu-system-x86_64 \
        "${creds[@]}" \
        -enable-kvm \
        -machine q35 \
        -cpu host \
        -smp 2 \
        -m 4096 \
        {{ ovmf }} \
        -drive file={{ img }},format=raw,if=virtio \
        {{ graphics }}

# Boot the image as a throwaway VM and open a shell in it. The VM is discarded on exit.
# Pass user=<name> to login as a non-root provisioned user.
[doc('Boot the image as a throwaway VM and open a shell in it.')]
[group('vm')]
vm user="": build
    #!/usr/bin/env bash
    set -euo pipefail
    kargs=()
    if [[ -n "{{ user }}" ]]; then
        pairs=$(just credentials {{ user }})
        while read -r cred; do
            kargs+=(--karg "systemd.set_credential_binary=$cred")
        done <<< "$pairs"
    fi
    bcvk ephemeral run-ssh "${kargs[@]}" {{ imgref }}

# Install the image to an encrypted raw disk image that can be booted or written
# to a device. Prompts for a passphrase. The install runs in a VM.
[doc('Install the image to an encrypted raw disk image.')]
[group('disk')]
disk: oci
    #!/usr/bin/env bash
    set -euo pipefail
    # bcvk creates the image when it is missing, so removing it clears the
    # previous run's partition table.
    rm -f {{ disk_img }}
    install="bootc-ubuntu-install \
    /dev/disk/by-id/virtio-target \
    oci:/run/virtiofs-mnt-repo/{{ oci_dir }}:{{ tag }} {{ imgref }}"
    bcvk ephemeral run-ssh --rm \
        --mount-disk-file "$PWD/{{ disk_img }}:target" \
        --bind "$PWD:repo" \
        {{ imgref }} \
        -t "$install"

# Boot the disk image from `just disk`.
[group('disk')]
boot user=user: (qemu-boot disk_img user)

# Build a live ISO that embeds the image for a fully offline install.
[group('iso')]
live *args: oci
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf .live
    mkdir .live
    trap 'rm -rf .live' EXIT
    cp -al {{ oci_dir }} .live/image.oci
    podman build --jobs 0 --target iso-out \
        --timestamp 0 \
        --build-context oci=.live \
        --build-arg ISO_NAME={{ name }} \
        --build-arg IMAGE_REF={{ imgref }} \
        --output type=local,dest=. \
        {{ args }} .

# Build a live ISO that pulls the image from its registry.
[group('iso')]
live-net *args: build
    podman build --jobs 0 --target iso-net-out \
        --timestamp 0 \
        --build-arg ISO_NAME={{ name }} \
        --build-arg IMAGE_REF={{ imgref }} \
        --output type=local,dest=. \
        {{ args }} .

# Build the network-install live ISO and checksum it for distribution.
[group('iso')]
dist: live-net
    sha256sum {{ iso }} > {{ iso }}.sha256

# Boot the live ISO in qemu against a blank disk.
[doc('Boot the live ISO against a blank disk, to install onto it.')]
[group('iso')]
live-install size="20G":
    #!/usr/bin/env bash
    set -euo pipefail
    rm -f {{ live_img }}
    truncate -s {{ size }} {{ live_img }}
    exec qemu-system-x86_64 \
        -enable-kvm \
        -machine q35 \
        -cpu host \
        -smp 4 \
        -m 8192 \
        {{ ovmf }} \
        -drive file={{ iso }},media=cdrom \
        -drive file={{ live_img }},format=raw,if=virtio \
        {{ graphics }}

# Boot the disk image `just live-install` installed to.
[group('iso')]
boot-live user=user: (qemu-boot live_img user)

# List running VMs.
[group('vm')]
vm-ps:
    @pgrep -a -f '[q]emu-system-x86_64 .*{{ name }}' || true
    @bcvk ephemeral ps || true

# Stop all running VMs.
[group('vm')]
vm-kill:
    -pkill -f '[q]emu-system-x86_64 .*{{ name }}'
    -bcvk ephemeral rm-all --force

# Remove the generated OCI archive, disk images and ISO.
clean:
    rm -rf {{ oci_dir }} {{ disk_img }} {{ live_img }} {{ iso }} {{ iso }}.sha256 .live
