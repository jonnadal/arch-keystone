# Arch Keystone

## Overview

Arch Keystone is an Arch Linux configuration with LUKS-protected Btrfs subvolumes and the Niri window manager.

**OS REFRESHES**. Rather than being an immutable OS, it facilitates a periodic "clean slate" refresh. This is done by creating a new `@os-${DATETIME}` subvolume for the root FS while retaining the previous one. systemd-boot defaults to the latest but lets you pick an earlier one if needed.

**DATA**. Data is persisted to a `@data` subvolume (mounted at `~/data`) unimpacted by the refreshes. Syncthing is available to replicate select subdirectories to other devices. Syncthing configuration varies by device so is persisted to `@data/local-only/syncthing` to survive refreshes.

**DURABILITY**. Periodically snapshotting `@data` protects against propagation of unintended file deletions with space-efficient local-only read-only snapshots. The author recommends alternating between at least two synced devices running Arch Keystone to periodically validate data replication and to have `@data` snapshots on multiple devices. If your devices are in the same location, then don't forget to have encrypted offsite backups as well.

**ISOLATION**. Tailscale is included for P2P VPN and the ability to specify an exit node. Tailscale configuration is persisted to `@data/local-only/tailscale` to also survive refreshes.

## Usage

1. Write an [Arch ISO](https://archlinux.org/download/) to a USB drive.
2. Copy the files to the same device.
3. Run `BOOTSTRAP.sh`.

