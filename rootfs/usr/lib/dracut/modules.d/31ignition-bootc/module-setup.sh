#!/bin/bash
# Distro integration for Ignition on ubuntu-bootc, the counterpart of Fedora
# CoreOS's ignition-ostree dracut module. The 30ignition module upstream ships
# is deliberately generic; wiring it to a specific root layout is left to us.
#
# Two jobs:
#
# 1. Stage a per-machine Ignition config off the ESP, which is how a bare-metal
#    machine gets one; see ignition-bootc-setup-user.sh.
#
# 2. Populate /var before the files stage runs. Ignition creates a user's home
#    directory as that user (as_user.MkdirAll), so
# /var/home has to exist before the files stage runs. bootc bind-mounts the
# deployment's /var during initrd-root-fs.target but nothing populates it until
# systemd-tmpfiles runs in the real root, which is too late.
#
# Numbered after 30ignition so its unit files are already in place.

# dracut sets moddir, initdir, systemdsystemunitdir and systemdsystemconfdir
# in the environment it sources this file from.
# shellcheck disable=SC2154

check() {
    # Only pulled in explicitly, alongside the ignition module.
    return 255
}

depends() {
    echo ignition
}

install() {
    local unit

    # cryptsetup: the files stage writes /etc/crypttab entries for every LUKS
    # device in the config and shells out to it for their UUIDs. Only
    # systemd-cryptsetup comes in with the crypt dracut modules.
    inst_multiple cryptsetup systemd-tmpfiles mktemp mount umount mkdir cp chmod mv

    unit=ignition-populate-var.service
    inst_simple "$moddir/$unit" "$systemdsystemunitdir/$unit"
    $SYSTEMCTL -q --root="$initdir" add-requires ignition-diskful.target "$unit" || exit 1

    # Storage is applied by /usr/lib/ubuntu-bootc/install, not on first boot:
    # re-running the disks stage against a config that describes an encrypted
    # root would wipe the root the machine just booted from. Dropping the unit
    # from the target is the only supported way to opt out; 30ignition wires it
    # in unconditionally.
    # systemctl add-requires writes into the config dir, so 30ignition's link
    # can be under either tree depending on how dracut was configured.
    rm -f "$initdir/$systemdsystemunitdir/ignition-complete.target.requires/ignition-disks.service" \
          "$initdir/$systemdsystemconfdir/ignition-complete.target.requires/ignition-disks.service"

    unit=ignition-bootc-setup-user.service
    inst_script "$moddir/ignition-bootc-setup-user.sh" \
        "/usr/sbin/ignition-bootc-setup-user"
    inst_simple "$moddir/$unit" "$systemdsystemunitdir/$unit"
    $SYSTEMCTL -q --root="$initdir" add-requires ignition-diskful.target "$unit" || exit 1
}
