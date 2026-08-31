# bootc-ubuntu

Ubuntu 26.04 as a [bootc](https://bootc-dev.github.io/bootc/) image. The image
provides a full system, built and shipped as a container image, updated
transactionally, with a read-only root filesystem on an optionally encrypted
disk.

`bootc-ubuntu` provides:

- `docker.io/yeetypete/bootc-ubuntu:26.04`, a minimal bootable base image
  for other projects to [derive from](#deriving-your-own-image).
- `docker.io/yeetypete/bootc-ubuntu-desktop:26.04`, a GNOME desktop derived
  from the base image and sealed into a unified kernel image.

## What's in the image

- Ubuntu 26.04, with GNOME desktop in the desktop image.
- `bootc` with the [composefs backend](https://bootc.dev/bootc/experimental-composefs.html)
  enabled for image storage and deployment, giving a read-only root filesystem
  verified with `fs-verity`.
- A [unified kernel image](https://uapi-group.org/specifications/specs/unified_kernel_image/)
  that boots only the root filesystem it was built with, and aborts if those
  contents have changed.

## Requirements

- A Linux host with [`just`](https://github.com/casey/just) and
  [Podman](https://podman.io/) to build the image.
- Only for VM tests: [`bcvk`](https://github.com/bootc-dev/bcvk) and
  QEMU.

> [!IMPORTANT]
> On an Ubuntu 25.10 or newer host, build `bcvk` from
> [bootc-dev/bcvk#329](https://github.com/bootc-dev/bcvk/pull/329). Ubuntu 25.10
> and newer include a `bwrap-userns-restrict` AppArmor profile, which denies
> capabilities to `bwrap`'s children, so `virtiofsd` exits at startup and the VM
> never finishes booting. On any other host the released `bcvk` works.

## Installing

Boot any Ubuntu live medium (or use an existing Ubuntu system with network
access) and run:

```bash
curl -fsSL https://github.com/yeetypete/bootc-ubuntu/raw/main/install.sh \
    | sudo bash -s -- /dev/nvme0n1  # The disk to install to, wiped.
```

The script asks for confirmation and a LUKS passphrase before it writes
anything. Arguments go to
[`bootc-ubuntu-install`](system_files/base/usr/libexec/bootc-ubuntu-install),
where `--encrypt off` leaves the root unencrypted. Reboot into the installed
system when it finishes.

To unlock with the TPM instead of a passphrase, enroll one afterwards with
[`systemd-cryptenroll`](https://www.freedesktop.org/software/systemd/man/latest/systemd-cryptenroll.html).

## Updates

Once installed, the system updates transactionally with `bootc upgrade`, which
pulls a newer image and stages it as a new deployment you can roll back to if
needed. See the [`bootc` upgrade docs](https://bootc-dev.github.io/bootc/upgrades.html).

## Accounts

The image ships no human accounts. One is provisioned at boot from systemd
credentials, so the same image can serve machines with different logins:

```bash
sysusers.extra:                 # u NAME 1000 "Real Name" /var/home/NAME /bin/bash
passwd.hashed-password.NAME:    # the output of `openssl passwd -6`
```

The desktop image needs neither, since GNOME Initial Setup creates the first
account on a machine that has none.

The system accounts that packages create are a different problem. `/etc` is
per-machine state that `bootc` carries across an upgrade with a three-way
merge, and a file the machine has modified is kept in preference to the
image's. `/etc/passwd` is modified the moment any account is added, so from
then on a system account introduced by a later image would never reach that
machine, and a daemon would fail to start or find its files owned by a UID
nobody has.

So `bootc-ubuntu-imagectl finalize` declares them at build time, with the UIDs
and GIDs they were built with, in one of two ways:

- `sysusers`, the default, writes
  `/usr/lib/sysusers.d/00-bootc-ubuntu-accounts.conf`. The accounts stay in
  `/etc`, and `systemd-sysusers` puts back at every boot whatever the merge
  dropped. The prefix matters: systemd takes the first declaration of a name
  in filename order, which is what lets a pinned ID here win over the dynamic
  one a package declares.
- `userdb` additionally moves the users to JSON records in `/usr/lib/userdb`,
  which `nss-systemd` resolves. They are then image content like any other
  file, so nothing about `/etc` can lose one or hold it at a stale UID.

```bash
just accounts=userdb build    # or: podman build --build-arg ACCOUNTS=userdb
```

Groups stay in `/etc/group` under either mode, declared in `sysusers.d`. The
`userdb` drop-in backend answers lookups by name and by ID but not membership
queries, so a group only it knew about would never reach `initgroups(3)`, and a
daemon started with `User=` would silently lose its supplementary groups.

Two other things to know before choosing `userdb`: a user that is not in
`/etc/passwd` is invisible to anything reading that file directly instead of
going through NSS, and the records are not in the initramfs.

Packages that ship a `sysusers.d` of their own are left alone, since Debian's
[`dh_installsysusers`](https://manpages.debian.org/testing/debhelper/dh_installsysusers.1.en.html)
is where this belongs in the long run and adopting it upstream shrinks what
has to be generated here. The exception is an account that owns something the
image ships: `/usr/bin/ssh-agent` is setgid `_ssh`, and `/etc/polkit-1/rules.d`
is only readable by `polkitd`. Ownership is recorded numerically, so those IDs
are pinned even when a package declares them without one.

### Keeping the IDs stable

An account's id is whatever was free when its package was installed, so it
depends on install order and moves when the package list changes. That only
matters where something records the number, and the image is scanned for
exactly that:

- Under `/etc`, `finalize` emits `tmpfiles.d` entries that reassert ownership
  by name at every boot, so the id may drift harmlessly. Nothing to maintain.
- Under `/var`, the entries `finalize` already generates name their owner, so
  the same applies.
- Under `/usr` there is no fix: it is read-only, and these are setgid binaries
  where the group is what gates access. `/usr/bin/ssh-agent` is setgid `_ssh`,
  and `/usr/lib/dbus-1.0/dbus-daemon-launch-helper` is setuid root and setgid
  `messagebus`. Those ids have to stay put.

So `/usr/lib/bootc-ubuntu/accounts.d/*.passwd` and `*.group` record them, in
the same format as the files they describe. `bootc-ubuntu-seed-accounts`
writes the entries before any package is installed, so maintainer scripts find
the account present and leave its id alone, and `finalize` fails if the built
image disagrees. A derived image whose packages own something under `/usr`
fails the build with the lines to add; anything else needs no attention.

## Testing in a VM

```bash
just build             # Build the image into podman storage.
just vm ubuntu         # Throwaway VM from the image, discarded on exit.

just disk              # Install it to bootc-ubuntu.img, in a VM, offline.
just boot ubuntu       # Boot bootc-ubuntu.img, with the console on this terminal.
```

`just disk` encrypts the root and prompts for a passphrase.
`just disk --encrypt off` installs unencrypted.

The recipes above run the VMs headless. Set `display` to open a window instead:

```bash
just display=gtk boot ""  # No account, so GDM runs GNOME Initial Setup.
```

## Deriving your own image

The base image is built to be derived from. Install packages, copy
configuration in, and finish with `bootc-ubuntu-imagectl finalize`, which the
base image ships.

```dockerfile
FROM docker.io/yeetypete/bootc-ubuntu:26.04

RUN apt-get update && apt-get install --no-install-recommends -y nginx && \
    systemctl enable nginx.service

# Contents land at the image root, so system_files/etc/nginx/nginx.conf
# becomes /etc/nginx/nginx.conf.
COPY system_files/ /

RUN /usr/libexec/bootc-ubuntu-imagectl finalize
```

`finalize` declares whatever accounts the derived image's own packages
created, on top of what the base image already declares, so it only has to run
once at the end. Pass `--build-arg ACCOUNTS=userdb` to match a base image built
that way.

Build and push it, then install it by pointing `install.sh` at it, or switch
an installed system to it with `bootc switch`:

```bash
curl -fsSL https://github.com/yeetypete/bootc-ubuntu/raw/main/install.sh \
    | sudo bash -s -- --image REGISTRY/IMAGE:TAG /dev/nvme0n1
```

The [`desktop` stage](Containerfile#L186) of the `Containerfile` is itself a
derived image, and can be used as an example of how to derive your own image.

## Installing tools transiently

For tracing and debugging tools that do not belong in the image, `bootc
usr-overlay` adds a writable overlay on `/usr` that is discarded on reboot:

```bash
sudo bootc usr-overlay
sudo apt update && sudo apt install -y strace
```

The overlay is backed by `tmpfs`, so anything installed into it lives in RAM and
is gone after a reboot. Note that changes under `/etc` and `/var`, which package
installations often make, persist. `bootc config-diff` can be used to list
what a package left behind in `/etc`. See the
[`bootc usr-overlay` docs](https://bootc-dev.github.io/bootc/man/bootc-usr-overlay.8.html).

Anything you want to keep should be later added to bootc image.

## License

`bootc-ubuntu` is released under the [MIT License](LICENSE).
