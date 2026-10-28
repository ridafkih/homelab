# Decisions

Short records of the choices behind this configuration: what was decided, why, and what follows from it. A later record that changes an earlier one says so at the top.

| # | Decision |
| --- | --- |
| [0001](0001-flake-layout-and-tests.md) | Flake layout, shared options and how tests are found |
| [0002](0002-secrets.md) | Secrets: one sops file, a key table and per-app env files |
| [0003](0003-compose-layout.md) | Compose layout and the lint rules |
| [0004](0004-image-pinning.md) | Every image pinned to the digest that runs today |
| [0005](0005-docker-and-compose-units.md) | Docker and the systemd units that run the Compose projects |
| [0006](0006-whole-box-mullvad-egress.md) | Whole-box Mullvad egress with a kill switch |
| [0007](0007-network-dns-and-firewall.md) | Network identity, DNS and firewall |
| [0008](0008-storage.md) | Data disks, mergerfs, and disko for the NVMe only |
| [0009](0009-nvidia.md) | NVIDIA driver and CDI for Jellyfin |
| [0010](0010-backups.md) | Selective on-disk backups; media is never backed up |
| [0011](0011-host-basics-and-ca-bundle.md) | smartd, the journald cap and the container CA bundle |
| [0012](0012-verification.md) | How the config is verified before cutover |
| [0013](0013-public-repo.md) | What may be public in this repo |
| [0014](0014-cutover.md) | Cutover from Arch |
