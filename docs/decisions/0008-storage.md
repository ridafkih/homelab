# 0008. Data disks, mergerfs, and disko for the NVMe only

## Context

The NVMe is wiped at cutover. The two data disks hold the media library and Seafile, and the media isn't backed up (0010), so nothing may ever format them.

## Decision

- `modules/storage.nix`: `/mnt/disk1` and `/mnt/disk2` by UUID, ext4, `nofail`, `noatime`, a 10-minute device timeout and `x-systemd.device-bound`. `/data` is a mergerfs pool over both with Arch's options. Docker requires and binds to all three mounts, so it fails closed if a disk is missing.
- The mounts follow the disks rather than the boot. Each disk mount is bound to its device. A udev rule matches the disks by filesystem UUID and starts `data-remount.service`, which is ordered after the disk mounts and starts `/data`; Docker and the Compose units are wanted by `/data`. The oneshot exists because a disk that comes back within seconds would otherwise race its mount's pending stop job, and a start that loses the race is never retried. Ordering makes systemd finish the stop first. smartd is ordered after and wanted by the disk mounts.
- `hosts/homelab/disks.nix`: disko describes only the NVMe, by its `by-id` path (a 1 GB EFI partition and ext4 root). An assertion fails the build if disko ever names another device.
- The Windows VM disk moves to `/data/windows` at cutover.

## Consequences

- A missing data disk keeps `/data` and Docker down until it comes back. When it does, even minutes late or under a new device name after a USB reset, the chain starts by itself.
- The 15-second timeout this replaced failed the whole chain on 2026-11-09, when the USB audio probe held udev for 25 seconds ([hardware](../hardware.md#the-onboard-usb-audio-stalls-udev)).
- The disk UUIDs and the NVMe's by-id path are public; they identify nothing outside the box.
