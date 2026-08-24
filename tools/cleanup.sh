#!/bin/bash
# Strip the rootfs of build-time state before it's sealed into an image.
set -euo pipefail

# Label paths with the source package that owns them, so chunkah splits the
# image into content-based layers instead of one layer per build stage. Must
# run before dpkg's database moves below.
#
# TODO: switch to chunkah's native dpkg backend and drop this step once
# https://github.com/coreos/chunkah/issues/155 lands.
/label-components /var/lib/dpkg

# Relocate the dpkg database to /usr so it persists across image updates
# (/var is only applied at first provisioning). A tmpfiles.d symlink restores
# /var/lib/dpkg.
mkdir -p /usr/lib/sysimage
mv /var/lib/dpkg /usr/lib/sysimage/dpkg

# Empty so systemd generates a real machine ID on first boot, instead of
# every install sharing this one.
: > /etc/machine-id

# Let sshd-keygen generate unique per-machine host keys on first boot. Delete
# the ones openssh-server's postinstall hook generates at build time.
rm -f /etc/ssh/ssh_host_*

# Let ssl-cert.service generate a unique per-machine snakeoil keypair on
# first boot. Delete the one ssl-cert's postinstall hook generates at build
# time.
find /etc/ssl/certs -lname ssl-cert-snakeoil.pem -delete
rm -f /etc/ssl/certs/ssl-cert-snakeoil.pem /etc/ssl/private/ssl-cert-snakeoil.key

# Drop the empty /etc/resolv.conf the base image ships, so systemd's stock
# tmpfiles rule can symlink it to the resolved stub at boot.
rm -f /etc/resolv.conf

# bootc expects /var empty (populated at boot via tmpfiles.d) and /run, /tmp
# clean.
rm -rf /run/* /tmp/* /var/log/*
find /var -mindepth 1 -type f -delete
find /var -mindepth 1 -type l -delete
find /var -mindepth 1 -type d -empty -delete
