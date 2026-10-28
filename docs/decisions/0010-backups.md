# 0010. Selective on-disk backups; media is never backed up

## Context

Arch backed up nightly into two restic repos, one per data disk, each holding the other disk's Seafile half. Backups stay on disk for now, and only what can't be replaced is backed up: if the media library is lost, it is lost.

## Decision

- Two native `services.restic.backups` jobs with the existing repos and password, so history carries over:
  - `disk1` writes the system set plus `/mnt/disk1/seafile` to `/mnt/disk2/backup/restic`.
  - `disk2` writes the system set plus `/mnt/disk2/seafile` to `/mnt/disk1/backup/restic`.
- The system set: `/etc`, `/root`, `/home/rida` (the checkout and its `.data`), `/var/lib/tailscale`, four Docker volumes (`homelab_grafana-funnel`, `homelab_signoz-sqlite`, `homelab_grafana`, `grafana_grafana-data`) and `/var/backups/homelab-db`. Nothing under `/data` is backed up; `modules/backup-excludes.txt` keeps Arch's excludes, with the Windows disk at `/data/windows`.
- Before `disk1` runs, `homelab-db-dumps` dumps Authentik's Postgres (`pg_dumpall`, checked for its completion line), Seafile's MariaDB (`mariadb-dump`, likewise) and OpenSEO's volumes (the project is stopped, archived with a checksummed manifest and started again).
- A timer starts `disk1` at 03:30 (persistent, 10 minutes of jitter); `disk1` wants `disk2`, which runs after it, so a failed dump doesn't cost the second copy.
- Prune keeps 7 daily, 4 weekly and 6 monthly snapshots, grouped by host and tags; each run checks 5% of the data. The password comes from sops. No remote repository of any kind.
- The host name must stay `homelab`; an assertion enforces it, because snapshots are grouped by it.

## Consequences

- The repos can't be read after the NVMe is wiped without the restic password, which is in sops, and the age keys, which are in 1Password.
- There are no failure alerts, as on Arch.
- `tests/backup.nix` proves in a VM that the media and Windows paths never reach either repo and that each repo holds the other disk's Seafile half. The VM smoke run's core tier runs the real `homelab-db-dumps` against the running databases and OpenSEO, and checks the dumps and that OpenSEO is running again afterwards.
