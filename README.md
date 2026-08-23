# bootc-ubuntu

Ubuntu 26.04 as a [bootc](https://bootc-dev.github.io/bootc/) image. The image
provides a full system, built and shipped as a container image, updated
transactionally, with a read-only root filesystem on an encrypted disk.

> [!WARNING]
> This repository is a **reference example** of running `bootc` on Ubuntu, not a
> base image for other projects to consume. Fork it and adapt the `Containerfile`
> and `rootfs/` to your own needs rather than depending on the published images.

## What's in the image

- Ubuntu 26.04 with GNOME desktop.
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
> and newer incldue a `bwrap-userns-restrict` AppArmor profile, which denies
> capabilities to `bwrap`'s children, so `virtiofsd` exits at startup and the VM
> never finishes booting. On any other host the released `bcvk` works.

## Installing

```bash
just live  # Build bootc-ubuntu.iso.
```

The ISO includes a bootc image. The installation does not require a network
connection.

To install, write the ISO to a USB device:

```bash
sudo cp bootc-ubuntu.iso /dev/sdX && sync
```

Boot the device, then follow the prompt. The live session lists the disks it
finds, and the installer asks for confirmation and a LUKS passphrase before it
writes anything:

```bash
bootc-ubuntu-install /dev/nvme0n1  # The disk to install to, wiped.
```

The installer then offers to reboot. Remove the installation medium at the
prompt, and go through GNOME's initial setup after the reboot.

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

just disk              # Install it to bootc-ubuntu.img, in a VM.
just boot ubuntu       # Boot bootc-ubuntu.img, with the console on this terminal.

just live              # Build bootc-ubuntu.iso.
just live-install      # Boot the ISO against a blank bootc-ubuntu-live.img, then
                       # run `bootc-ubuntu-install in the live session.
just boot-live ubuntu  # Boot bootc-ubuntu-live.img, the ISO install.
```

The recipes above run the VMs headless. Set `display` to open a window instead:

```bash
just display=gtk boot ""  # No account, so GDM runs GNOME Initial Setup.
```

> [!NOTE]
> Passing no user leaves a freshly installed disk without an account, so GDM
> shows GNOME Initial Setup instead of the login screen. Create the first
> account there.

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
