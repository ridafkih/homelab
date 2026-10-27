# Host config

Files under `host/` mirror their path on the Arch host (`host/etc/fstab` is `/etc/fstab`). They are the source of truth until the host moves to NixOS; copy a file into place with `sudo install` and reload the service it belongs to.

## Logs

- `etc/docker/daemon.json`: json-file logs rotate at 10 MB × 3 per container. The setting applies only to containers created after it, so recreate containers (`docker compose up -d --force-recreate`) after changing it.
- `etc/systemd/journald.conf.d/size.conf`: journald is capped at 1 GB.

## Disks

- `etc/smartd.conf`: smartd watches every disk by id, runs a short self-test daily at 02:00 and a long one on the 1st of each month at 03:00. Alerts only reach the journal until a notifier is wired in.
- `etc/fstab`: data disks mount by UUID with `nofail`. Never run `mount -a` while `/data` is mounted: mergerfs reports its source as `1:2`, so `mount -a` does not see it as mounted and stacks a second mergerfs on top of `/data`, hiding `/data/timemachine`. Undo with a single `umount /data`.

## GPU

- `etc/systemd/system/nvidia-docker-arch.service` creates the NVIDIA device nodes and regenerates `/etc/cdi/nvidia.yaml` before `docker.service` starts, so `restart: always` GPU containers find a current CDI spec and `/dev/nvidiactl` at boot. The toolkit runtime config and CDI mode are persisted and no longer rewritten at boot.
- `etc/systemd/system/jellyfin-ensure.service` is the old retry workaround. Remove it once a reboot shows Jellyfin starting without it.

## OpenSEO

- `etc/systemd/system/openseo.service` runs `docker compose up -d --wait` for `/home/rida/homelab/openseo` after docker.service (so after the NVIDIA units) and once tailscale0 holds 100.100.81.126. The stack publishes only on that address, which docker cannot bind before Tailscale is up.

## Backups

- `usr/local/sbin/homelab-backup` (run nightly at 03:30 by `homelab-backup.timer`) dumps the authentik, Keeper and Seafile databases, then backs up system config, the home directory and the dumps with restic. Exclusions are in `etc/homelab-backup/excludes`: media, models, caches, logs and regenerable metadata stay out.
- There are two repositories, `/mnt/disk1/backup/restic` and `/mnt/disk2/backup/restic`. Each holds the system set plus the Seafile files from the other disk, so either disk can fail without losing Seafile data. A Seafile restore merges both halves back into `/data/seafile`.
- The repository password is `/root/.config/restic/homelab.pass`, with copies at `/mnt/disk{1,2}/backup/restic.pass`. None of this is off-site yet.
- OpenSEO: the backup stops its app containers for about 40 seconds, archives the `storage` and `config` volumes to `/var/backups/homelab-db/openseo` in the upstream `scripts/celld/backup.mjs` format (restore with `node scripts/celld/backup.mjs restore DIR` from an open-seo checkout, `COMPOSE_FILE=/home/rida/homelab/openseo/compose.yaml`), then starts them again. Its `.env` is covered by `/home/rida`.
