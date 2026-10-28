# 0008. Data disks, mergerfs, and disko for the NVMe only

## Context

The NVMe is wiped at cutover. The two data disks hold the media library and Seafile, and the media isn't backed up (0010), so nothing may ever format them.

## Decision

- `modules/storage.nix`: `/mnt/disk1` and `/mnt/disk2` by UUID, ext4, `nofail`, `noatime`, a 15-second device timeout. `/data` is a mergerfs pool over both with Arch's options. Docker requires and binds to all three mounts, so it fails closed if a disk is missing.
- `hosts/homelab/disks.nix`: disko describes only the NVMe, by its `by-id` path (a 1 GB EFI partition and ext4 root). An assertion fails the build if disko ever names another device.
- The Windows VM disk moves to `/data/windows` at cutover.

## Consequences

- A missing data disk keeps `/data` and Docker down until fixed by hand, as on Arch.
- The disk UUIDs and the NVMe's by-id path are public; they identify nothing outside the box.
