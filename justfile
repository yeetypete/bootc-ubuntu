# bootc-ubuntu developer tasks.

set default-list := true

# Version for image labels and the tag suffix, without its leading "v".
version := "0.0.0"
# Git commit SHA for image labels.
revision := `git rev-parse HEAD 2>/dev/null || echo ""`
# Short SHA for tags.
short_revision := replace_regex(revision, '^(.{7}).*$', '$1')
# Commit date, recorded as the image creation time.
created := `git log -1 --pretty=%cI 2>/dev/null || echo ""`
# Tag the image is built with.
tag := "26.04"
# Registry repository holding the layer cache, e.g. docker.io/yeetypete/bootc-ubuntu-cache.
cache_repo := ""

# Local OCI layout the image is exported to.
oci_dir := "image.oci"
# Registry reference of the built image, as the installed system refers to it.
imgref := "docker.io/yeetypete/bootc-ubuntu-desktop:" + tag
# Tag identifying this particular build.
build_tag := tag + "-" + short_revision
# Registry reference pinned to the commit, which every build is tagged with.
revision_imgref := imgref + "-" + short_revision
# Registry reference for a tagged release.
version_imgref := imgref + "-" + version
# The same references for the base image.
base_imgref := "docker.io/yeetypete/bootc-ubuntu:" + tag
base_revision_imgref := base_imgref + "-" + short_revision
base_version_imgref := base_imgref + "-" + version
push_args := "--compression-format zstd --force-compression"
cache_args := if cache_repo == "" { "" } else { "--cache-from " + cache_repo + " --cache-to " + cache_repo }
labels := "--label org.opencontainers.image.created=" + created + \
    " --label org.opencontainers.image.version=" + version + \
    " --label org.opencontainers.image.revision=" + revision
base_labels := labels + \
    " --label org.opencontainers.image.title=bootc-ubuntu" + \
    " --label 'org.opencontainers.image.description=Ubuntu 26.04 as a bootc base image'"
desktop_labels := labels + \
    " --label org.opencontainers.image.title=bootc-ubuntu-desktop" + \
    " --label 'org.opencontainers.image.description=Ubuntu 26.04 GNOME desktop as a bootc image'"
# The base rootfs as built, before chunking.
base_target := "localhost/bootc-ubuntu-base-target:" + tag
# The base image, chunked.
base_chunked := "localhost/bootc-ubuntu-base:" + tag
# The desktop rootfs as built, before chunking and sealing.
target := "localhost/bootc-ubuntu-target:" + tag
# The rootfs repacked into content-based layers, which the UKI is sealed against.
chunked := "localhost/bootc-ubuntu-chunked:" + tag
# Firmware for the boot recipe. Booting this image needs UEFI.
ovmf := "-drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,unit=1,readonly=on,file=/usr/share/OVMF/OVMF_VARS_4M.fd"
# Base name of the generated disk image.
name := "bootc-ubuntu"
# Disk image `just disk` installs to, and `just boot` boots. bcvk sizes it for us.
disk_img := if variant == "base" { name + "-base.img" } else { name + ".img" }
# Account provisioned into a test VM.
user := "ubuntu"
# Which image the vm recipe builds and boots, "desktop" or "base".
variant := "desktop"
variant_imgref := if variant == "base" { base_imgref } else if variant == "desktop" { imgref } \
    else { error("variant must be desktop or base, not " + variant) }
variant_build := if variant == "base" { "build-base" } else { "build" }
# QEMU display for the VM recipes. "none" keeps the console on this terminal;
# set display=gtk for a window, the only way to see the desktop.
display := "none"
graphics := if display == "none" { "-nographic" } else { "-vga none -device virtio-vga-gl -display " + display + ",gl=on -serial mon:stdio" }

# Repack `src` into content-based layers, tagged `dst`.
[private]
chunk src dst *args:
    #!/usr/bin/env bash
    set -euo pipefail
    work=$(mktemp -d -p /var/tmp)
    trap 'rm -rf "${work}"' EXIT
    config=$(podman inspect {{ src }})
    podman run --rm \
        --mount=type=image,src={{ src }},dst=/chunkah \
        -e CHUNKAH_CONFIG_STR="${config}" \
        -v "${work}:/out:z" \
        {{ src }} /usr/libexec/bootc-ubuntu-imagectl rechunk \
            --output oci:/out/layout \
            --tag {{ dst }} \
            {{ args }}
    podman pull --quiet "oci:${work}/layout:{{ dst }}"

# Build the base image: the finalized rootfs, repacked into content-based layers.
[group('image')]
build-base *args:
    podman build --jobs 0 --target base-rootfs \
        {{ base_labels }} \
        --timestamp 0 \
        {{ cache_args }} \
        --tag {{ base_target }} \
        {{ args }} .
    just chunk {{ base_target }} {{ base_chunked }}
    podman tag {{ base_chunked }} {{ base_imgref }} {{ base_revision_imgref }}

# Build the desktop image from the base image in three steps:
#
# 1. Build the rootfs, derived from the base image.
# 2. Repack it into content-based layers.
# 3. Seal the repacked rootfs into the UKI and assemble the final image.
#
# chunkah runs before the UKI is sealed because it rewrites the file mtimes that
# the sealed composefs digest covers.
[doc('Build the desktop image from the base image.')]
[group('image')]
build *args: build-base
    podman build --jobs 0 --target kernel-split \
        --build-arg BASE_IMAGE={{ base_chunked }} \
        --timestamp 0 \
        {{ cache_args }} \
        --tag {{ target }} \
        {{ args }} .
    just chunk {{ target }} {{ chunked }} --prune /kernel
    podman build --jobs 0 --target image \
        --build-arg BASE_IMAGE={{ base_chunked }} \
        --build-context chunked=container-image://{{ chunked }} \
        {{ desktop_labels }} \
        --timestamp 0 \
        {{ cache_args }} \
        --tag {{ imgref }} \
        --tag {{ revision_imgref }} \
        {{ args }} .

# Export the bootc container image as an OCI directory.
[group('image')]
oci:
    just {{ variant_build }}
    rm -rf {{ oci_dir }}
    podman push --quiet --compression-format zstd {{ variant_imgref }} oci:{{ oci_dir }}:{{ build_tag }}

# Push the images to their registries under the commit they were built from.
[group('image')]
push: build
    podman push {{ push_args }} {{ base_revision_imgref }}
    podman push {{ push_args }} {{ revision_imgref }}

# Publish a tagged release.
[group('image')]
push-release: push
    podman push {{ push_args }} {{ base_revision_imgref }} docker://{{ base_version_imgref }}
    podman push {{ push_args }} {{ base_imgref }}
    podman push {{ push_args }} {{ revision_imgref }} docker://{{ version_imgref }}
    podman push {{ push_args }} {{ imgref }}

# Switch this machine to the locally built image.
[group('image')]
switch *args: oci
    sudo bootc switch --transport oci {{ args }} {{ justfile_directory() }}/{{ oci_dir }}:{{ build_tag }}

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
[doc('Boot the image as a throwaway VM and open a shell in it.')]
[group('vm')]
vm user="":
    #!/usr/bin/env bash
    set -euo pipefail
    just {{ variant_build }}
    kargs=()
    if [[ -n "{{ user }}" ]]; then
        pairs=$(just credentials {{ user }})
        while read -r cred; do
            kargs+=(--karg "systemd.set_credential_binary=$cred")
        done <<< "$pairs"
    fi
    bcvk ephemeral run-ssh "${kargs[@]}" {{ variant_imgref }}

# Run CMD in a VM, with a fresh disk image attached as "target" and the repo
# bound at /run/virtiofs-mnt-repo.
[private]
install-vm cmd *args:
    #!/usr/bin/env bash
    set -euo pipefail
    # bcvk creates the image when it is missing, so removing it clears the
    # previous run's partition table.
    rm -f {{ disk_img }}
    bcvk ephemeral run-ssh --rm \
        --mount-disk-file "$PWD/{{ disk_img }}:target" \
        --bind "$PWD:repo" \
        {{ args }} \
        {{ variant_imgref }} \
        -t "{{ cmd }}"

# Install the image to an encrypted raw disk image that can be booted or written
# to a device. Prompts for a passphrase. The install runs in a VM.
[doc('Install the image to an encrypted raw disk image.')]
[group('disk')]
disk: oci
    #!/usr/bin/env bash
    set -euo pipefail
    install="/usr/libexec/bootc-ubuntu-install \
    /dev/disk/by-id/virtio-target \
    oci:/run/virtiofs-mnt-repo/{{ oci_dir }}:{{ build_tag }} {{ variant_imgref }}"
    just install-vm "$install"

# Install to a disk image through install.sh.
[group('disk')]
disk-script: oci
    #!/usr/bin/env bash
    set -euo pipefail
    # Point podman at the host's image store, which bcvk mounts read-only.
    install="sudo CONTAINERS_STORAGE_CONF=/run/virtiofs-mnt-repo/tests/vm-storage.conf \
    bash /run/virtiofs-mnt-repo/install.sh \
    --image {{ variant_imgref }} \
    --source oci:/run/virtiofs-mnt-repo/{{ oci_dir }}:{{ build_tag }} \
    /dev/disk/by-id/virtio-target"
    just install-vm "$install" --bind-storage-ro --add-swap 8G

# Boot the disk image from `just disk`.
[group('disk')]
boot user=user:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ -f {{ disk_img }} ]] || { echo "{{ disk_img }} does not exist." >&2; exit 1; }
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
        -drive file={{ disk_img }},format=raw,if=virtio \
        {{ graphics }}

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

# Remove the generated OCI archive and disk images.
clean:
    rm -rf {{ oci_dir }} {{ name }}*.img
