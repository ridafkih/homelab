# Homelab

The NixOS configuration and Docker Compose apps for my home server, `homelab`.

## Hardware

A Ryzen 7 7800X3D with 64 GB of RAM and an RTX 4080 Super, used headless for Jellyfin transcodes. NixOS runs from a 2 TB NVMe. Two hard drives (12 TB and 16 TB) are pooled at `/data` with mergerfs. Details, disk IDs and the USB port rule are in [docs/hardware.md](./docs/hardware.md).

## What runs

NixOS runs the host: networking, Tailscale, the NVIDIA driver, storage, backups and the egress policy. Everything else is a Docker Compose app under `apps/`:

- `caddy`: reverse proxy and TLS for the `rida.sh` subdomains, with Cloudflare DNS challenges
- `authentik`: single sign-on, reached from outside through its own Cloudflare tunnel
- `adguard`: DNS for the box and the tailnet
- `jellyfin`: media server, with NVENC on the 4080
- `media`: Prowlarr, Sonarr, Radarr, Bazarr, qBittorrent, qui and Jellyseerr
- `seafile`: file sync and sharing, with SeaDoc
- `open-webui`: Open WebUI
- `observability`: OpenTelemetry Collector, Prometheus, Loki, Tempo, Grafana and SigNoz, with a Tailscale Funnel for OTLP
- `ridash`: the Cloudflare tunnel for `rida.sh`
- `openseo`: OpenSEO, as its own Compose project
- `windows`: a Windows 11 VM, as its own Compose project

## Layout

```text
flake.nix          the flake; nixosConfigurations.homelab and the checks
flake.lock         pinned nixpkgs, sops-nix and disko
hosts/homelab/     the host: hardware, disko layout, secrets wiring, the test VM
modules/           one NixOS module per concern (backup, egress, storage, DNS, ...)
apps/              one directory per Compose app, plus its config files
compose.yaml       the homelab project, which includes the apps under apps/
homelab.env        non-secret settings shared by the Compose apps
secrets/           sops-encrypted secrets and the map from secrets to env files
scripts/           Compose lint and diff, the VM smoke run, the secrets migration
tests/             NixOS VM tests, eval checks and doc checks
docs/              hardware, restore, cutover, build host and decision records
.github/           CI: evaluates the flake and builds the host
```

## Deploy

On the box, from the checkout:

```bash
sudo nixos-rebuild switch --flake .#homelab
```

Each Compose project runs as a systemd unit: `homelab-compose` (everything in `compose.yaml`), `openseo-compose` and `windows-compose`. A switch reloads a unit when its secrets change. To pick up a Compose change or restart one app:

```bash
sudo systemctl reload homelab-compose
sudo docker restart jellyfin
journalctl -u homelab-compose
```

Images are pinned by digest. `nix flake check` runs the tests; [docs/build-host.md](./docs/build-host.md) covers building and the VM smoke run.

## Secrets

Secrets live in `secrets/homelab.yaml`, encrypted with sops to two age keys: the host's (`/var/lib/sops-nix/key.txt` on the box) and an admin key. Both private keys are kept in 1Password. Nothing secret is ever committed in plaintext. sops-nix decrypts them at boot, and `secrets/keys.tsv` says which env file under `/run/secrets/rendered` each one lands in. To edit:

```bash
sops secrets/homelab.yaml
```

`secrets/vm.yaml` and `secrets/test-age.key` are throwaway values for the test VM.

## Backups

Backups are on-disk only, with restic, every night at 03:30. There is no off-site copy for now. The two repos are crossed, so each disk's Seafile half is backed up onto the other disk:

- `/mnt/disk2/backup/restic` holds disk1's Seafile half
- `/mnt/disk1/backup/restic` holds disk2's Seafile half

Both also hold `/etc`, `/root`, the checkout and its app data, Tailscale's state, a few Docker volumes and nightly dumps of the Authentik, Seafile and OpenSEO databases. The media library (`/data/media`) is never backed up: if it goes, it goes. The Windows VM disk is excluded too.

Restoring files, Seafile and the databases is in [docs/restore.md](./docs/restore.md).

## Egress

The whole box, host and containers, goes out through Mullvad via a Tailscale exit node. The egress policy is a kill switch: if Tailscale or the exit node is down, traffic fails closed instead of leaking to the ISP. LAN and Docker traffic stay local.

There is one exception: the two Cloudflare tunnels (Authentik and `rida.sh`) connect straight to Cloudflare's tunnel edge, because Cloudflare refuses tunnel connections from Mullvad's relays. Only Cloudflare's published tunnel-edge prefixes skip Mullvad, and Cloudflare already knows the box from the tunnel tokens. See [0008](./docs/decisions/0008-whole-box-mullvad-egress.md).

## Not carried over

Pi-hole, Ollama and Keeper.sh no longer run here. The rest of what was left behind is listed in [docs/hardware.md](./docs/hardware.md#not-carried-over).

## Moving the box over

[docs/cutover.md](./docs/cutover.md) is the runbook for installing this config on the box, and for rolling back.

## License

[MIT](./LICENSE)
