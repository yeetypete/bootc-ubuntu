# bootc-ubuntu developer tasks.

# Image repository for the built image.
image := "yeetypete/bootc-ubuntu"
# Version for image labels and the tag suffix, without its leading "v".
version := trim_start_match("v0.0.0", "v")
# Git commit SHA for image labels.
revision := `git rev-parse HEAD 2>/dev/null || echo ""`
# Tag the image is built with.
tag := "26.04"

# Local OCI layout the image is exported to.
oci_dir := "image.oci"
# Registry reference of the built image, as the installed system refers to it.
imgref := "docker.io/" + image + ":" + tag
# Firmware for the qemu recipes. Booting this image needs UEFI.
ovmf := "-drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,unit=1,readonly=on,file=/usr/share/OVMF/OVMF_VARS_4M.fd"
# Name of the disk image produced by `just disk`. bcvk sizes it for us.
disk_name := "bootc-ubuntu"
# Account provisioned into a test VM.
user := "ubuntu"

# List available recipes.
default:
    @just --list

# Build the bootc container image.
build *args:
    podman build --target image \
        --label org.opencontainers.image.version={{ version }} \
        --label org.opencontainers.image.revision={{ revision }} \
        --tag {{ imgref }} \
        --tag {{ imgref }}-{{ version }} \
        {{ args }} .

# Export the bootc container image as an OCI directory.
oci: build
    rm -rf {{ oci_dir }}
    podman push --quiet {{ imgref }} oci:{{ oci_dir }}:{{ tag }}

# Push the image to its registry.
push: build
    podman push {{ imgref }}
    podman push {{ imgref }}-{{ version }}

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

# Boot the image as a throwaway VM and open a shell in it. The VM is discarded on exit.
# Pass user=<name> to login as a non-root provisioned user.
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
disk: oci
    #!/usr/bin/env bash
    set -euo pipefail
    # bcvk creates the image when it is missing, so removing it clears the
    # previous run's partition table.
    rm -f {{ disk_name }}.img
    install="bootc-ubuntu-install \
    /dev/disk/by-id/virtio-target \
    oci:/run/virtiofs-mnt-repo/{{ oci_dir }}:{{ tag }} {{ imgref }}"
    bcvk ephemeral run-ssh --rm \
        --mount-disk-file "$PWD/{{ disk_name }}.img:target" \
        --bind "$PWD:repo" \
        {{ imgref }} \
        -t "$install"

# Build a live ISO that boots this image and installs it.
live *args: oci
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf .live
    mkdir .live
    trap 'rm -rf .live' EXIT
    cp -al {{ oci_dir }} .live/image.oci
    podman build --target iso-out \
        --build-context oci=.live \
        --build-arg ISO_NAME={{ disk_name }} \
        --build-arg IMAGE_REF={{ imgref }} \
        --output type=local,dest=. \
        {{ args }} .

# Boot the live ISO in qemu against a blank disk.
live-vm target_size="20G":
    #!/usr/bin/env bash
    set -euo pipefail
    target={{ disk_name }}-target.img
    [[ -f $target ]] || truncate -s {{ target_size }} "$target"
    qemu-system-x86_64 \
        -enable-kvm \
        -machine q35 \
        -cpu host \
        -smp 4 \
        -m 8192 \
        {{ ovmf }} \
        -drive file={{ disk_name }}.iso,media=cdrom \
        -drive file="$target",format=raw,if=virtio \
        -nographic

# Boot the disk image from `just disk` in qemu, with the console on this terminal.
boot user=user:
    #!/usr/bin/env bash
    set -euo pipefail
    creds=()
    if [[ -n "{{ user }}" ]]; then
        pairs=$(just credentials {{ user }})
        # SMBIOS separates the pair with = rather than :.
        while read -r cred; do
            creds+=(-smbios "type=11,value=io.systemd.credential.binary:${cred/:/=}")
        done <<< "$pairs"
    fi
    qemu-system-x86_64 \
        "${creds[@]}" \
        -enable-kvm \
        -machine q35 \
        -cpu host \
        -smp 2 \
        -m 4096 \
        {{ ovmf }} \
        -drive file={{ disk_name }}.img,format=raw,if=virtio \
        -nographic

# Remove the generated OCI archive, disk images and ISO.
clean:
    rm -rf {{ oci_dir }} {{ disk_name }}.img {{ disk_name }}-target.img \
        {{ disk_name }}.iso .live
