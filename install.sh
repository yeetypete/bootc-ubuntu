#!/bin/bash
# Install bootc-ubuntu onto a disk, wiping it, from any Ubuntu live session or
# installed system with network access:
#
#     curl -fsSL https://github.com/yeetypete/bootc-ubuntu/raw/main/install.sh \
#         | sudo bash -s -- /dev/nvme0n1
#
# Options go to bootc-ubuntu-install, which does the install.
set -euo pipefail

# The image to install, and the registry reference the installed system
# fetches updates from.
IMAGE="${IMAGE:-docker.io/yeetypete/bootc-ubuntu-desktop:26.04}"
usage() {
    echo "Usage: install.sh DISK [IMAGE [SOURCE]] [ARG...]" >&2
}

fatal() {
    echo "install.sh: $*" >&2
    exit 1
}

if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
    usage
    exit 0
fi

args=()
while [[ $# -gt 0 && "$1" != -* ]]; do
    args+=("$1")
    shift
done
install_args=("$@")

disk="${args[0]-}"
IMAGE="${args[1]-${IMAGE}}"
# Where bootc installs from, in containers-transports(5) form, defaulting to
# the image in the host's container storage.
SOURCE="${args[2]-${SOURCE:-containers-storage:${IMAGE}}}"

[[ ${EUID} -eq 0 ]] || fatal "must run as root."
if [[ -z "${disk}" ]]; then
    usage
    echo >&2
    lsblk --nodeps --output NAME,SIZE,MODEL >&2
    exit 2
fi
[[ -b "${disk}" ]] || fatal "${disk} is not a block device."

# Piped from curl, stdin is the script itself. Reattach the terminal for the
# installer's prompts.
if [[ ! -t 0 && -e /dev/tty ]]; then
    exec </dev/tty
fi

if ! command -v podman >/dev/null; then
    echo "Installing podman."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates podman
fi

# An oci: source is a path, resolved inside the container, so absolutize it
# and mount it at the same place.
volumes=()
if [[ "${SOURCE}" == oci:* ]]; then
    rest="${SOURCE#oci:}"
    tag=""
    [[ "${rest}" == *:* ]] && tag=":${rest#*:}"
    dir="$(realpath "${rest%%:*}")"
    SOURCE="oci:${dir}${tag}"
    volumes=(-v "${dir}:${dir}:ro")
fi

# The containers-storage source reads the host's image storage, mounted in.
exec podman run --rm -it --privileged --pid=host --ipc=host \
    -v /dev:/dev -v /run/udev:/run/udev:ro \
    -v /var/lib/containers:/var/lib/containers \
    "${volumes[@]}" \
    "${IMAGE}" /usr/libexec/bootc-ubuntu-install \
    "${install_args[@]}" "${disk}" "${SOURCE}" "${IMAGE}"
