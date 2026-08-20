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
# Name of the disk image produced by `just disk`. bcvk sizes it for us.
disk_name := "ubuntu-bootc"
# Scratch space the install VM gets for unpacking the image.
scratch_size := "8G"
# Account provisioned into a test VM, recreated as the base image had it.
user := "ubuntu"
# Groups the base image's "ubuntu" user belonged to.
user_groups := "adm dialout cdrom floppy sudo audio dip video plugdev"

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
    account=$({
        printf 'u %s 1000 "Ubuntu" /var/home/%s /bin/bash\n' {{ name }} {{ name }}
        for group in {{ user_groups }}; do
            printf 'm %s %s\n' {{ name }} "$group"
        done
    } | base64 -w0)
    hashed=$(printf '%s' "$(openssl passwd -6 "$password")" | base64 -w0)
    printf 'sysusers.extra:%s\n' "$account"
    printf 'passwd.hashed-password.{{ name }}:%s\n' "$hashed"

# Boot the image as a throwaway VM and open a shell in it. The VM is discarded on exit.
# Pass user=<name> to login as a non-root provisioned user.
vm user="": load
    #!/usr/bin/env bash
    set -euo pipefail
    kargs=()
    if [[ -n "{{ user }}" ]]; then
        pairs=$(just credentials {{ user }})
        while read -r cred; do
            kargs+=(--karg "systemd.set_credential_binary=$cred")
        done <<< "$pairs"
    fi
    bcvk ephemeral run-ssh "${kargs[@]}" docker.io/{{ image }}:{{ tag }}

# Install the image to an encrypted raw disk image that can be booted or written
# to a device. Prompts for a passphrase. The install runs in a VM.
disk: load
    #!/usr/bin/env bash
    set -euo pipefail
    # bcvk creates the image when it is missing, so removing it clears the
    # previous run's partition table.
    rm -f {{ disk_name }}.img
    # In the VM /var is a tmpfs carved out of /run which is too small to
    # unpack the image into. Give /var/tmp its own tmpfs backed by the swap
    # device. This is what bcvk does in its own to-disk.
    install="mount -t tmpfs -o size={{ scratch_size }} tmpfs /var/tmp && \
    /usr/lib/ubuntu-bootc/install-encrypted.py \
    --karg console=ttyS0,115200 --karg console=tty0 \
    /dev/disk/by-id/virtio-target \
    oci-archive:/run/virtiofs-mnt-repo/{{ oci_archive }}:{{ tag }} docker.io/{{ image }}:{{ tag }}"
    bcvk ephemeral run-ssh --rm --add-swap {{ scratch_size }} \
        --mount-disk-file "$PWD/{{ disk_name }}.img:target" \
        --bind "$PWD:repo" \
        docker.io/{{ image }}:{{ tag }} \
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
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive if=pflash,format=raw,unit=1,readonly=on,file=/usr/share/OVMF/OVMF_VARS_4M.fd \
        -drive file={{ disk_name }}.img,format=raw,if=virtio \
        -nographic

# Remove the generated OCI archive and disk image.
clean:
    rm -rf {{ oci_archive }} {{ disk_name }}.img
