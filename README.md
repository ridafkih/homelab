# Homelab

The Docker Compose setup for my home server, `homelab`, as it runs today on Arch Linux.

The box is moving to NixOS. The new configuration, with the host declared as a NixOS flake, one folder per app, encrypted secrets, selective on-disk backups and all traffic through Mullvad, is on the [`nixos` branch](https://github.com/ridafkih/homelab/tree/nixos). It replaces this branch when the box is cut over; [docs/cutover.md](https://github.com/ridafkih/homelab/blob/nixos/docs/cutover.md) on that branch is the runbook.

## Hardware

A Ryzen 7 7800X3D with 64 GB of RAM and an RTX 4080 Super, used headless for Jellyfin transcodes. Arch runs from a 2 TB NVMe, and two hard drives are pooled at `/data` with mergerfs.

## What runs

- Caddy: reverse proxy and TLS for the `rida.sh` subdomains, with Cloudflare DNS challenges
- Authentik: single sign-on, reached from outside through its own Cloudflare tunnel
- AdGuard Home: DNS for the box and the tailnet
- Jellyfin: media server, with NVENC on the 4080
- Prowlarr, Sonarr, Radarr, Bazarr, qBittorrent, qui and Jellyseerr
- Seafile, with SeaDoc
- Open WebUI
- Observability: OpenTelemetry Collector, Prometheus, Loki, Tempo, Grafana and SigNoz, with a Tailscale Funnel for OTLP
- A Cloudflare tunnel for `rida.sh`
- OpenSEO, as its own Compose project in `openseo/`
- A Windows 11 VM, kept outside this repo

Pi-hole, Ollama and Keeper.sh no longer run here.

## Layout

```text
compose.yaml   every service above except OpenSEO and the Windows VM
config/        config files the containers mount
openseo/       the OpenSEO Compose project
host/          the Arch host's own files: fstab, systemd units, the backup script, the firewall rule
Makefile       make up, down, restart, pull and ps
.env.example   the settings and secrets the stack reads from .env
```

## Running it

Copy `.env.example` to `.env` and fill it in, then:

```bash
make up
make down
docker logs <container>
```

## License

[MIT](./LICENSE)
