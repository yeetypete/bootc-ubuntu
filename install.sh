#!/bin/bash
# Install bootc-ubuntu onto a disk, wiping it, from any Ubuntu live session or
# installed system with network access:
#
#     curl -fsSL https://github.com/yeetypete/bootc-ubuntu/raw/main/install.sh \
#         | sudo bash -s -- /dev/nvme0n1
set -euo pipefail

IMAGE="${IMAGE:-docker.io/yeetypete/bootc-ubuntu-desktop:26.04}"
INSTALLER=/usr/libexec/bootc-ubuntu-install

usage() {
    echo "Usage: install.sh [--image REF] [--volume DIR] ARG..." >&2
    echo "Arguments go to ${INSTALLER} in the image, which takes the disk." >&2
}

fatal() {
    echo "install.sh: $*" >&2
    exit 1
}

args=()
volumes=()
while [[ $# -gt 0 ]]; do
    case "$1" in
    --image)
        IMAGE="$2"
        shift 2
        ;;
    --volume)
        dir="$(realpath "$2")"
        volumes+=(-v "${dir}:${dir}:ro")
        shift 2
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        args+=("$1")
        shift
        ;;
    esac
done

[[ ${EUID} -eq 0 ]] || fatal "must run as root."
if [[ ${#args[@]} -eq 0 ]]; then
    usage
    echo >&2
    lsblk --nodeps --output NAME,SIZE,MODEL >&2
    exit 2
fi

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

# The installer reads the host's image storage, mounted in.
exec podman run --rm -it --privileged --pid=host --ipc=host \
    -v /dev:/dev -v /run/udev:/run/udev:ro \
    -v /var/lib/containers:/var/lib/containers \
    "${volumes[@]}" \
    "${IMAGE}" "${INSTALLER}" "${args[@]}"
