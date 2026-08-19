#!/bin/bash
# Stage a per-machine Ignition config off the ESP into the initramfs, where
# Ignition looks for user configs.
#
# Ignition's own bare-metal options are ignition.config.url= (network, or a
# data: URL bounded by the kernel cmdline length) and ignition.config.device=,
# which is not in a released Ignition yet. Fedora CoreOS has the same gap and
# fills it the same way, from coreos-ignition-setup-user.
set -euo pipefail

LABEL="${IGNITION_CONFIG_LABEL:-EFI-SYSTEM}"
SRC="${IGNITION_CONFIG_PATH:-/ignition/config.ign}"
# Ignition v2.26.0 searches a single directory, /usr/lib/ignition, which is
# read-only in the initramfs under systemd's ProtectSystem= defaults. The
# /run/ignition + /etc/ignition search path that replaces it is not in a
# release yet, so point this release at /run/ignition instead: the same
# tmpfs Ignition already keeps its state and neednet flag in.
DEST=/run/ignition/user.ign
ENVFILE=/run/ignition.env
DEV="/dev/disk/by-label/${LABEL}"

# A config already staged by something else wins; this is a fallback source.
[[ -e $DEST ]] && exit 0

# udev may not have settled by the time we run.
for _ in {1..50}; do
    [[ -e $DEV ]] && break
    sleep 0.1
done
[[ -e $DEV ]] || { echo "no device labelled ${LABEL}; skipping" >&2; exit 0; }

mnt="$(mktemp -d)"
trap 'umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true' EXIT
mount "$DEV" "$mnt"

if [[ -f "$mnt/$SRC" ]]; then
    # The initramfs has a small userspace; stick to bash builtins and the
    # handful of binaries module-setup.sh installs.
    mkdir -p "${DEST%/*}"
    cp "$mnt/$SRC" "$DEST"
    chmod 0600 "$DEST"
    # Every ignition-*.service reads this file, so one line covers all stages.
    echo "IGNITION_SYSTEM_CONFIG_DIR=${DEST%/*}" >> "$ENVFILE"
    # Consume the config so it applies exactly once. ignition.firstboot stays
    # on the kernel command line - systemd-boot has no way to drop it, unlike
    # the GRUB snippet Fedora CoreOS uses - so the config's presence is what
    # marks the boot as a provisioning boot. Re-running Ignition against an
    # applied config is not harmless: it resets the password of every user in
    # the config, and any storage.files entry without overwrite fails the
    # files stage, which drops the machine into emergency mode. With no config
    # the stages run and pass in well under a second.
    mv "$mnt/$SRC" "$mnt/$SRC.applied"

    echo "staged Ignition config from ${LABEL}:${SRC}"
else
    echo "no config at ${LABEL}:${SRC}; skipping" >&2
fi
