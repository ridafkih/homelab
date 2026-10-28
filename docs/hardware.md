# Hardware

What the box is, where its data lives, and what was deliberately left behind when it moved from Arch to NixOS. The NixOS side of these facts is in `hosts/homelab/hardware.nix`, `hosts/homelab/disks.nix`, `modules/storage.nix`, `modules/nvidia.nix` and `modules/monitoring.nix`. The cutover itself is in [cutover.md](cutover.md).

## The box

| Part | What it is |
| --- | --- |
| CPU | AMD Ryzen 7 7800X3D, 16 threads, with an iGPU that drives the console |
| Memory | 64 GB (61 GiB usable), no swap |
| GPU | NVIDIA RTX 4080 SUPER, used headless for Jellyfin's NVENC transcodes through CDI ([0011](decisions/0011-nvidia-driver-and-cdi.md)) |
| System disk | WD_BLACK SN850X 2 TB NVMe, `/dev/disk/by-id/nvme-WD_BLACK_SN850X_2000GB_23523B800268` |
| Firmware | UEFI; NixOS boots with systemd-boot from a 1 GB ESP |
| Network | `eno1` on the LAN at 10.0.0.98 (DHCP, pinned client ID); the Wi-Fi card `wlp9s0` is left unmanaged |
| Remote console | GL.iNet KVM: console, power control and virtual media |
| Data disks | Two hard drives in a TerraMaster TDAS USB enclosure |

The kernel takes no extra parameters. Arch had `nomodeset module_blacklist=nvidia_drm`, added by hand during the 2026-10-10 boot hangs. Those hangs came from the USB enclosure (below), not the GPU, so neither flag was carried over.

## Keep the TDAS on the chipset 10G USB port

The TDAS is three ASMedia `174c:235c` SATA bridges behind a Realtek `0bda:0423` hub, driven by `uas`. It has to stay plugged into the chipset's 10 Gbps xHCI controller (PCI `0a:00.0`, bus 2 in `lsusb -t`), not the CPU's 5 Gbps controller (bus 4).

The history behind the rule: while the enclosure sat on bus 4, every boot logged dozens of UAS errors (`-71`, `uas_eh_abort_handler`) on the data disks, between 34 and 75 per boot, and two boots in a row hung on 2026-10-10. It moved to bus 2 at 15:15 that day, and there have been none since, on the same kernel.

The port was the fix, so there is no `usb-storage.quirks` entry for the bridges, and none should be added. A quirk would force the slower BOT protocol and only cost throughput.

Checking it after any hardware change:

```sh
lsusb -t | grep -B1 -A4 '0bda:0423\|uas'
journalctl -k -b | grep -cE 'uas_eh_abort|error -71'
```

The hub and its three `uas` devices hang off the 10000M root hub, and the count is 0. If they appear under the 5000M root hub, move the cable before doing anything else.

## Disks

| Disk | Mounted at | Filesystem and UUID | Role |
| --- | --- | --- | --- |
| NVMe (SN850X 2 TB) | `/`, `/boot` | ext4 and vfat, created by disko | The OS, Docker (`/var/lib/docker`, including the named volumes), the checkout at `/home/rida/homelab` and its `.data` |
| disk1 (Seagate ST12000VN0008, 12 TB) | `/mnt/disk1` | ext4, `fa876494-200f-4c5d-95d6-0db79304bed7` | Half of the `/data` pool, one Seafile half (`/mnt/disk1/seafile`), and the restic repo `/mnt/disk1/backup/restic` |
| disk2 (Seagate ST16000NT001, 16 TB) | `/mnt/disk2` | ext4, `62a0f9e6-258d-4ae7-a952-78c462d51c49` | The other half of the pool, the other Seafile half (`/mnt/disk2/seafile`), the restic repo `/mnt/disk2/backup/restic`, and the cutover's working area under `/mnt/disk2/migration` |
| sda (Seagate ST2000DM006, 2 TB) | nothing | NTFS from an old Windows install | Not declared; `modules/monitoring.nix` still has smartd watch it |
| The KVM's virtual drives | nothing | none | Appear as a USB flash drive and an optical drive when the GL.iNet KVM's virtual media is on; never declared |

Only the NVMe is in disko (`hosts/homelab/disks.nix`), and an eval assertion refuses any other target. Nothing in this repo ever formats or partitions the data disks.

Both data disks mount by UUID with `nofail`, `noatime` and a 15 second device timeout, and `/data` is a mergerfs pool over them (`category.create=mfs`, so new files land on whichever disk has more free space). Docker is bound to all three mounts and won't start without them ([0010](decisions/0010-storage-and-disko.md)).

What lives where on the pool:

- `/data/media` is the media library. It is never backed up: if the disks go, it goes.
- `/data/seafile` is Seafile's block store, split across the two disks as `/mnt/disk1/seafile` and `/mnt/disk2/seafile`. Seafile's database is not on the pool: it is the Docker volume `homelab_seafile-database` on the NVMe, and the nightly dump of it goes into restic.
- `/data/windows` is the Windows VM's disk (sparse, 64 GB apparent). It is excluded from backups, as it was on Arch.
- `timemachine.img` on disk2 (about 600 GB) is the old Time Machine image. It is left where it is, not mounted and not served.

Backups are on-disk only and cross the disks ([0012](decisions/0012-selective-on-disk-backups.md), `modules/backup.nix`): the `disk1` job writes the system set plus disk1's Seafile half to `/mnt/disk2/backup/restic`, and the `disk2` job writes the system set plus disk2's Seafile half to `/mnt/disk1/backup/restic`. Losing one disk loses one Seafile half and one repo, and the other repo still holds that half.

## Not carried over

These were on the Arch box and are intentionally not part of the NixOS config.

| What | Why |
| --- | --- |
| `~/grafana`, the standalone Grafana stack from March | Replaced by the observability stack in this repo. Its volume `grafana_grafana-data` is still copied with the other volumes and stays in the backup set until someone deletes it. |
| Samba (`nmbd` running, `smbd` masked, a `WindowsDrive` share on an empty `/mnt/windows`) | Nothing used it; Seafile replaced the file share. Ports 137 and 138 are closed. |
| The Time Machine loop mount of `timemachine.img` at `/data/timemachine` | No share served it and it was last written in June 2026. The image file stays on disk2. |
| sda, the 2 TB NTFS disk | Unused. It is never mounted or declared, so nothing on it changes. |
| `nightly-reboot.service` and `.timer` | Disabled by hand on 2026-10-21; there is no reason to reboot nightly. |
| `jellyfin-ensure.service` and Docker's `daemon.json` | Docker restart policies and the Nix Docker settings replace them. |
| `nvidia-docker-arch.service` and the Docker drop-ins for `nvidia-uvm` | The CDI generator ordering in `modules/nvidia.nix` covers them. |
| The pacman hook that rebuilt the container CA bundle | `modules/trust.nix` builds the bundle instead. |
| The macvlan `local-network` the two cloudflared containers used to dodge the exit node | The egress policy's Cloudflare edge rule replaces it ([0008](decisions/0008-whole-box-mullvad-egress.md)). |
| The `.data` dirs `llama-cpp`, `vllm`, `pihole`, `pihole-tailscale` and `mitmproxy` (about 90 GB) | Leftovers from services that no longer run. |
| Pi-hole, Ollama and Keeper.sh | No longer run on this box. |
| The kernel parameters `nomodeset` and `module_blacklist=nvidia_drm` | They were a guess during the USB hangs above. |
