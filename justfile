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

# Install the image to a raw disk image that can be booted or written to a device.
disk:
    truncate -s {{ disk_size }} {{ disk_name }}.img
    docker run \
        --rm --privileged \
        --security-opt label=disable \
        -v /dev:/dev \
        -v "$PWD:/output" \
        {{ image }}:{{ tag }} \
        bootc install to-disk \
            --source-imgref oci-archive:/output/{{ oci_archive }}:{{ tag }} \
            --target-imgref docker.io/{{ image }}:{{ tag }} \
            --composefs-backend \
            --karg console=ttyS0,115200 \
            --karg console=tty0 \
            --via-loopback /output/{{ disk_name }}.img

# Boot the disk image from `just disk` in qemu, with the console on this terminal.
boot:
    cp /usr/share/OVMF/OVMF_VARS_4M.fd {{ disk_name }}-vars.fd
    qemu-system-x86_64 \
        -enable-kvm -m 4096 -smp 2 -cpu host -machine q35 \
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive if=pflash,format=raw,unit=1,file={{ disk_name }}-vars.fd \
        -drive file={{ disk_name }}.img,format=raw,if=virtio \
        -nographic

# Remove the generated OCI archive and disk image.
clean:
    rm -rf {{ oci_archive }} {{ disk_name }}.img {{ disk_name }}-vars.fd
