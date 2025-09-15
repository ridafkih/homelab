# Homelab

Configuration files and dockerized container configurations for the services I run on my own home lab.

## Prerequisites

1. Install Docker on your host.
2. Install and configure Tailscale on your host.
3. Prepare a domain name to be used for your homelab, set this domain to to `CADDY_DOMAIN` environment variable.
4. Install a compatible NVIDIA graphics card alongside the compatible drivers.
5. If you're planning on using the Jellyfin media server, create and mount the /data/media directory to store your media files.

## Services

- Network
  - [tailscale](https://github.com/tailscale/tailscale)
  - [caddy](https://github.com/caddy/caddy)
  - [pi-hole](https://github.com/pi-hole/pi-hole)
- Media
  - [jellyfin](https://github.com/jellyfin/jellyfin)
- AI
  - [ollama](https://github.com/ollama/ollama)
  - [open-webui](https://github.com/open-webui/open-webui)

## Usage

```bash
# Start all services
make up

# Start specific profiles
docker compose --profile network up -d
docker compose --profile media up -d
docker compose --profile ai up -d

# Stop all services
make down
```

## Setup

1. Copy `.env.example` to `.env` and configure variables
2. Configure `config/Caddyfile` for your domain
3. Run `make up`

## Specifications

This is run on a system with the following specifications.

- AMD AM5 Ryzen 7 7800X3D
- 64GB DDR5 RAM
- GeForce RTX 3090 Founders Edition
- Arch Linux
