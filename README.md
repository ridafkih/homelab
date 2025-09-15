# Homelab

Configuration files and dockerized container configurations for the services I run on my own home lab.

## Considerations

This exact configuration requires an NVIDIA GPU, but modification of the [compose.yaml](./compose.yaml) can remove that requirement by removing references to the NVIDIA runtime.

## Services

### Network

#### Tailscale

Tailscale is an easy-to-use VPN configuration, allowing you to securely access your home lab, or any other system on your "tailnet" anywhere without requiring you to expose it to the internet. This simplifies both configuration, as well as the security posture of your configuration significantly.

#### Caddy

Caddy is a reverse-proxy, similar to Nginx without the regular pains of managing an Nginx instance. Caddy easily and automatically configures your certificates and easily routes to services within your Docker network.

#### Pi-hole

Pi-hole is an easily-configurable DNS server that can be used to block or modify DNS requests. It's very useful for network-level analytics & ad-blocking.

### Media

#### Jellyfin

Jellyfin is a great alternative to other popular options, like Plex. It hosts media, doing all the heavy-lifting for serving content to various clients.

As far as clients go, I'd highly recommend [Jellyfin's official companion application for Android](https://play.google.com/store/apps/details?id=org.jellyfin.mobile&hl=en_CA&pli=1) or your Android-compatible television, or the [Streamyfin application on the Apple App Store](https://apps.apple.com/us/app/streamyfin/id6593660679). They are both very well made, and work flawlessly.

### Artificial Intelligence

#### Ollama

Ollama is an easy-to-use OpenAI API compatible server that can be used to easily mount and serve compatible models to services and clients that have access to your homelab.

#### Open WebUI

Open WebUI is an extensible, and well-crafted UI that is compatible with both Ollama & OpenAI API compatible services. It's great for quickly accessing and interacting with the models you have installed on Ollama.

## Prerequisites

First, start by copying the `.env.example` to a `.env` file in the root directory and configuring it as you wish.

```bash
cp .env.example .env
```

### Configuring Docker

You can follow Docker's official [installation documentation](https://docs.docker.com/desktop/setup/install/linux/) to get started with installing it. It is vital to this project, which hosts all the services it can inside containers.

### Configuring Tailscale

Tailscale is used to access the home lab remotely, and is baked into this project to serve the DNS resolver to avoid conflicting with the configuration of the host. With that said, you should follow [their official documentation](https://tailscale.com/kb/1031/install-linux) to get started on installing it for your Linux distro.

### Preparing for Jellyfin

The media server mounts a hard-coded directory, where it will be used to access files. Before running Jellyfin, you should mount a directory you plan on storing your media to /data/media/.

### Preparing for Caddy

#### Cloudflare

Use Cloudflare to manage your DNS, this will allow Caddy to automatically manage your ACME TXT records and the DNS-01 challenge.

Once you've configured Cloudflare to manage your DNS.

1. Click on the Profile icon on the top-right of the Cloudflare dashboard.
2. Click "API Tokens" on the sidebar.
3. Click "Create Token"
4. Under "Permissions" configure the token to be able to read zone information, and edit DNS information.
   1. Zone, Zone, Read
   2. Zone, DNS, Edit
5. Under "Zone Resource" configure the token to be able to access your domain settings.
   1. Include, Specific zone, example.net
6. Save your token, and use it for the `CADDY_CLOUDFLARE_API_TOKEN`.

Use the domain of your choice, and in your registrar's DNS settings, configure a single wildcard `A` record under the domain, or subdomain of your choice - pointing to the local (IPv4) address of the home lab on your tailnet. This is the same domain that will be used to access your services.

As an example, if you wanted to serve your home lab to the domain name `example.net`, you would configure your environment variable.

```
CADDY_CLOUDFLARE_API_TOKEN=********************************
CADDY_DOMAIN=example.net
```

#### DNS Settings

Once that's done, configure your domain, or a subdomain of your choice to serve the local IP address of your server on your Tailscale network.

```
Type        Name        Content            Proxy        TTL
A           *           100.xxx.xxx.92     DNS only     Auto
```

With all said and done, Caddy will be able to automatically add the ACME TXT records, and manage TLS for the services. You can access the services under the subdomains of your `CADDY_DOMAIN`.

- pihole.example.net
- jellyfin.example.net
- ollama.example.net
- open-webui.example.net

These can be configured in [the Caddyfile](./config/Caddyfile)

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

## Getting Started

Once you've configured everything, you can run the services.

```bash
make up
```

You can stop services just as easily.

```bash
make down
```

Use the Docker CLI to find containers, and access logs if containers don't work as expected.

```
docker ps
docker logs ollama
```

## Specifications

This is run on a system with the following specifications.

- AMD AM5 Ryzen 7 7800X3D
- 64GB DDR5 RAM
- GeForce RTX 3090 Founders Edition
- Arch Linux

## Contributions

Unlikely, but feel free to contribute issues if you have questions or want any support in spinning a similar configuration up yourself - I'll be happy to assist.

## LICENSE

MIT License
