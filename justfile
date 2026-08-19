# ubuntu-bootc developer tasks.

# Image repository for the built image.
image := "yeetypete/ubuntu-bootc"
# Version for image labels and tag suffix (docker bake strips a leading "v").
version := "v0.0.0"
# Git commit SHA for image labels.
revision := `git rev-parse HEAD 2>/dev/null || echo ""`
# Whether `build` also pushes the image to the registry (set push=true on releases).
push := "false"
# Tag the image is built with.
tag := "26.04"

oci_archive := "image.oci"
# Name and size of the disk image produced by `just disk`.
disk_name := "ubuntu-bootc"
disk_size := "20G"
# Memory for the VM that runs the install. /tmp there is half of this, and the
# install needs room to unpack the image.
install_memory := "8192"

# List available recipes.
default:
    @just --list

# Build the bootc container image.
build *args:
    IMAGE={{ image }} VERSION={{ version }} REVISION={{ revision }} PUSH={{ push }} \
        docker buildx bake ubuntu-bootc {{ args }}

# Load the built image into podman storage, which is where bcvk reads from.
load:
    podman pull oci-archive:{{ oci_archive }}:{{ tag }}

# Boot the image as a throwaway VM and open a shell in it. The VM is discarded on exit.
vm: load
    bcvk ephemeral run-ssh docker.io/{{ image }}:{{ tag }}

# Install the image to an encrypted raw disk image that can be booted or written
# to a device. Prompts for a passphrase. The install runs in a VM.
disk: load
    #!/usr/bin/env bash
    set -euo pipefail
    truncate -s {{ disk_size }} {{ disk_name }}.img
    # /var/tmp is a 1.6G tmpfs in the VM, too small to unpack into.
    install="mount --bind /tmp /var/tmp && \
    /usr/lib/ubuntu-bootc/install-encrypted.py \
    --karg console=ttyS0,115200 --karg console=tty0 /dev/vda \
    oci-archive:/run/virtiofs-mnt-repo/{{ oci_archive }}:{{ tag }} docker.io/{{ image }}:{{ tag }}"
    bcvk ephemeral run-ssh --rm --memory {{ install_memory }} \
        --mount-disk-file "$PWD/{{ disk_name }}.img:target" \
        --bind "$PWD:repo" \
        docker.io/{{ image }}:{{ tag }} \
        -t "$install"

# Boot the disk image from `just disk` in qemu, with the console on this terminal.
boot:
    qemu-system-x86_64 \
        -enable-kvm \
        -machine q35 \
        -cpu host \
        -smp 2 \
        -m 4096 \
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive if=pflash,format=raw,unit=1,readonly=on,file=/usr/share/OVMF/OVMF_VARS_4M.fd \
        -drive file={{ disk_name }}.img,format=raw,if=virtio \
        -nographic

# Remove the generated OCI archive and disk image.
clean:
    rm -rf {{ oci_archive }} {{ disk_name }}.img
