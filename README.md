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

Build and push it, then install it by pointing `install.sh` at it, or switch
an installed system to it with `bootc switch`:

```bash
curl -fsSL https://github.com/yeetypete/bootc-ubuntu/raw/main/install.sh \
    | sudo bash -s -- --image REGISTRY/IMAGE:TAG /dev/nvme0n1
```

The [`desktop` stage](Containerfile#L178) of the `Containerfile` is itself a
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
