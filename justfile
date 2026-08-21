# ubuntu-bootc developer tasks.

# Image repository for the built image.
image := "yeetypete/ubuntu-bootc"
# Version for image labels and the tag suffix, without its leading "v".
version := trim_start_match("v0.0.0", "v")
# Git commit SHA for image labels.
revision := `git rev-parse HEAD 2>/dev/null || echo ""`
# Tag the image is built with.
tag := "26.04"

oci_archive := "image.oci"
# Registry reference of the built image, as the installed system refers to it.
imgref := "docker.io/" + image + ":" + tag
# Firmware for the qemu recipes. Booting this image needs UEFI.
ovmf := "-drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,unit=1,readonly=on,file=/usr/share/OVMF/OVMF_VARS_4M.fd"
# Name of the disk image produced by `just disk`. bcvk sizes it for us.
disk_name := "ubuntu-bootc"
# Scratch space the install VM gets for unpacking the image.
scratch_size := "8G"
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

# Export the bootc container image as an OCI archive.
archive: build
    podman push --quiet {{ imgref }} oci-archive:{{ oci_archive }}:{{ tag }}

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
    # The UID is spelled out because sysusers allocates from the system range
    # otherwise, and a login below UID_MIN is hidden from the login screen.
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
disk: archive
    #!/usr/bin/env bash
    set -euo pipefail
    # bcvk creates the image when it is missing, so removing it clears the
    # previous run's partition table.
    rm -f {{ disk_name }}.img
    # In the VM /var is a tmpfs carved out of /run which is too small to
    # unpack the image into. Give /var/tmp its own tmpfs backed by the swap
    # device. This is what bcvk does in its own to-disk.
    install="mount -t tmpfs -o size={{ scratch_size }} tmpfs /var/tmp && \
    ubuntu-bootc-install \
    /dev/disk/by-id/virtio-target \
    oci-archive:/run/virtiofs-mnt-repo/{{ oci_archive }}:{{ tag }} {{ imgref }}"
    bcvk ephemeral run-ssh --rm --add-swap {{ scratch_size }} \
        --mount-disk-file "$PWD/{{ disk_name }}.img:target" \
        --bind "$PWD:repo" \
        {{ imgref }} \
        -t "$install"

# Boot the disk image from `just disk` in qemu, with the console on this terminal.
boot user=user:
    #!/usr/bin/env bash
    set -euo pipefail
    creds=()
    if [[ -n "{{ user }}" ]]; then
        pairs=$(just credentials {{ user }})
        # SMBIOS spells the pair name=value rather than name:value.
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
    rm -rf {{ oci_archive }} {{ disk_name }}.img {{ disk_name }}-target.img \
        {{ disk_name }}.iso .live
