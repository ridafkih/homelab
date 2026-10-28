# Restore

How to get data back out of the nightly restic backups. Backups are on-disk only, defined in `modules/backup.nix` ([0010](decisions/0010-backups.md)).

## What is where

Two jobs run back to back from `restic-backups-disk1.timer` at 03:30. Each repo lives on one data disk and holds the other disk's Seafile half, so either disk can die without losing Seafile.

| Job and wrapper | Repo | Seafile half it holds |
| --- | --- | --- |
| `restic-disk1` | `/mnt/disk2/backup/restic` | `/mnt/disk1/seafile` |
| `restic-disk2` | `/mnt/disk1/backup/restic` | `/mnt/disk2/seafile` |

Both repos also hold the same system set: `/etc`, `/root`, the checkout with its `.data` (`/home/rida/homelab`), `/var/lib/tailscale`, four Docker volumes under `/var/lib/docker/volumes`, and the database dumps in `/var/backups/homelab-db`. The dumps are written just before `restic-disk1` runs, so both repos carry the same night's dumps.

`/data/media` and the Windows VM disk (`/data/windows`) are never backed up. Media can't be restored; if a disk goes, the media on it goes too.

## The restic password

On the running box, sops-nix renders it to `/run/secrets/restic/RESTIC_PASSWORD` and the `restic-disk1` and `restic-disk2` wrappers already point at it and at their repo. Run everything on the box as root (`sudo -i`): the repos, the dumps and the restored files are all root-only.

If the NVMe is gone, the password is still in `secrets/homelab.yaml`, encrypted to the two age keys in `.sops.yaml`. Both private keys are in 1Password (`homelab sops admin age key` and `homelab sops host age key`). From a machine with 1Password and a checkout, decrypt it straight into tmpfs on the box (booted from the NixOS installer or a fresh install):

```bash
SOPS_AGE_KEY="$(op read 'op://<vault>/homelab sops admin age key/<field>')" sops -d --extract '["restic"]["RESTIC_PASSWORD"]' secrets/homelab.yaml | ssh <box> 'sudo sh -c "umask 077 && cat > /run/restic.pass"'
```

Then, as root on the box, use plain restic with that file wherever this guide says `restic-disk1` or `restic-disk2`, and delete it when done. On the installer, mount the data disks at `/mnt/disk1` and `/mnt/disk2` first, read-only unless you are restoring onto them.

```bash
nix-shell -p restic
restic -r /mnt/disk2/backup/restic --password-file /run/restic.pass snapshots
rm /run/restic.pass
```

To bring the box itself back, the host key must be at `/var/lib/sops-nix/key.txt` before the first boot, as in [cutover.md](cutover.md#state):

```bash
op read 'op://<vault>/homelab sops host age key/<field>' | ssh <box> 'sudo sh -c "umask 077 && install -d -m 0700 /var/lib/sops-nix && cat > /var/lib/sops-nix/key.txt"'
```

## Listing and checking

```bash
restic-disk1 snapshots --tag homelab
restic-disk2 snapshots --tag homelab
restic-disk1 ls latest /etc/ssh
restic-disk1 check
```

`check` without flags reads only the repo's structure; add `--read-data` to read every pack, which takes hours on the Seafile half. The nightly run already checks a random 5% of the data.

## One file or folder

```bash
restic-disk1 restore latest --target /tmp/restore --include <path>
```

The file lands at `/tmp/restore<path>` with its owner and mode. Look at it, then copy it into place. Use a snapshot ID from `snapshots` instead of `latest` for an older version.

## Seafile

Seafile's block store and its database have to come from the same night. Mixing a database from one night with blocks from another corrupts libraries, so pick one run and take everything from it.

1. Find the run. Pick a `restic-disk1` snapshot and the `restic-disk2` snapshot taken a few minutes after it:

   ```bash
   restic-disk1 snapshots --tag homelab --path /mnt/disk1/seafile
   restic-disk2 snapshots --tag homelab --path /mnt/disk2/seafile
   ```

2. Stop Seafile, leaving its database running:

   ```bash
   docker stop seadoc seafile
   ```

3. Restore both halves. If one disk died, restore only its half and keep the surviving half as it is.

   ```bash
   restic-disk1 restore <disk1-snapshot> --target / --include /mnt/disk1/seafile
   restic-disk2 restore <disk2-snapshot> --target / --include /mnt/disk2/seafile
   ```

4. Load that run's database dump (next section) into `seafile-db`.

5. Start Seafile and check every library:

   ```bash
   docker start seafile seadoc
   docker exec seafile /opt/seafile/seafile-server-latest/seaf-fsck.sh
   ```

   `seaf-fsck` only reports. If it lists damaged libraries, run it again with `--repair`. Anything uploaded after the chosen night is gone.

## Database dumps

Each night writes `authentik-postgresql.sql` (`pg_dumpall --clean --if-exists`), `seafile-db.sql` (`mariadb-dump --all-databases`) and the `openseo/` archive to `/var/backups/homelab-db`. Restore them to a scratch directory first:

```bash
restic-disk1 restore <snapshot> --target /tmp/restore --include /var/backups/homelab-db
```

Authentik. Stop the server and worker so nothing holds the database open, load the dump, then start them. Errors about dropping or creating the `authentik` role are expected: the dump tries to recreate the user it is connected as.

```bash
docker stop authentik-server authentik-worker
docker exec -i authentik-postgresql psql -U authentik -d postgres < /tmp/restore/var/backups/homelab-db/authentik-postgresql.sql
docker start authentik-server authentik-worker
```

Seafile. Run this with `seafile` and `seadoc` stopped (step 2 above):

```bash
docker exec -i seafile-db sh -c 'exec mariadb -uroot -p"$MYSQL_ROOT_PASSWORD"' < /tmp/restore/var/backups/homelab-db/seafile-db.sql
```

## OpenSEO

The `openseo/` folder holds `storage.tar.gz` and `config.tar.gz`, the contents of the `openseo_storage` and `openseo_config` volumes, plus a `manifest.json` with their sha256 sums. Check the sums first:

```bash
cd /tmp/restore/var/backups/homelab-db/openseo
for f in storage.tar.gz config.tar.gz; do grep -qF "\"$f\":\"$(sha256sum "$f" | cut -d' ' -f1)\"" manifest.json && echo "$f ok"; done
```

Both must print `ok`. Then replace the volumes' contents with the stack stopped. On a fresh box, start and stop `openseo-compose` once first so the volumes exist.

```bash
systemctl stop openseo-compose
for v in storage config; do
  find /var/lib/docker/volumes/openseo_$v/_data -mindepth 1 -delete
  tar --numeric-owner -xzf $v.tar.gz -C /var/lib/docker/volumes/openseo_$v/_data
done
systemctl start openseo-compose
```

## Docker volumes

Only four volumes are backed up as files: `homelab_grafana`, `homelab_grafana-funnel`, `homelab_signoz-sqlite` and `grafana_grafana-data`. The database volumes come back from the dumps above. Stop whatever uses the volume, restore it in place and start it again:

```bash
docker stop grafana
restic-disk1 restore latest --target / --include /var/lib/docker/volumes/homelab_grafana
docker start grafana
```

## Tailscale

The node's identity is `/var/lib/tailscale`. Do this from the LAN or the KVM console, since the tailnet and all outbound traffic drop while tailscaled is stopped:

```bash
systemctl stop tailscaled
restic-disk1 restore latest --target / --include /var/lib/tailscale
systemctl start tailscaled
```

## Replacing a dead disk

The new disk needs its UUID in `modules/storage.nix` and an empty restic repo at its backup path, because the jobs never create one (`initialize = false`). After the switch, create the repo with the wrapper whose repo lived on the dead disk (`restic-disk2` for disk1, `restic-disk1` for disk2), restore Seafile's half as above, and run `systemctl start restic-backups-disk1` to take a fresh pair of snapshots.

```bash
restic-disk2 init
```
