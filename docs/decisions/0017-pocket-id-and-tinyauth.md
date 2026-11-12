# 0017. Pocket ID for sign-in, Tinyauth in front of apps without OIDC

## Context

Authentik (four containers and its own Cloudflare tunnel) only served Tailscale's custom OIDC login. Every app behind Caddy kept its own login. The goal is one passkey sign-in for everything.

## Decision

- Pocket ID runs on the host from the nixpkgs module (`modules/sso.nix`), on port 1411, at `https://id.rida.sh`. Its encryption key and static API key are sops secrets loaded as systemd credentials.
- `id.rida.sh` is public, because Tailscale's control plane fetches discovery, keys and tokens from it. The `rida.sh` Cloudflare tunnel carries it: the tunnel's remote config routes `id.rida.sh` to `http://rida.sh-bun` (Caddy's plain-HTTP side), and Caddy's `http://id.rida.sh` site proxies to Pocket ID. That route and its proxied CNAME live in Cloudflare, not in this repo.
- Containers that talk to Pocket ID server-side resolve `id.rida.sh` to Caddy through a network alias on `homelab-network`, so they never leave the box.
- Groups and OIDC clients are declared in `modules/sso.nix`. `pocket-id-provision` applies them through the API on every switch: it creates what is missing, updates what drifted and sets each confidential client's secret from sops. Users, their passkeys and their group memberships are state in Pocket ID's database, not config; `pocket-id-invite` creates a user and prints a one-time sign-in link.
- Tinyauth runs on the host on port 3820 at `https://auth.rida.sh`, signs in only through Pocket ID, and answers Caddy's `forward_auth` for apps without OIDC. Its app rules (domain and required group) are declared in the same module; anything not listed is denied.
- The firewall accepts ports 1411 and 3820 from the Docker networks (`172.16.0.0/12`) and the tailnet only. Caddy sits on several networks and its source address depends on the route, so the rule cannot narrow to `homelab-network`. Tinyauth's settings live in one JSON file (`TINYAUTH_CONFIGFILE`), port included: with only `TINYAUTH_SERVER_PORT` set next to the config file, it listened on its default port 3000 and took it from AdGuard's web UI.
- Pocket ID's SQLite database is dumped nightly with `.backup`, and both state directories are in the restic paths.

## Consequences

- Passkeys are bound to `id.rida.sh`; changing that host loses every registered passkey.
- Losing Pocket ID locks out every app's SSO path, so each app keeps a local admin login until its SSO is proven.

## Apps

| App | Sign-in | Notes |
| --- | --- | --- |
| Tailscale | Pocket ID (`tailscale` client) | WebFinger at `rida.sh` names `https://id.rida.sh` as the issuer |
| Jellyfin | Pocket ID through the K0lin SSO plugin, `media` group | matched to the existing user by username; password login and Quick Connect stay for the TV and phone apps |
| Open WebUI | Pocket ID, `admins` group | merged into the existing account by email, sign-ups off |
| Seafile | Pocket ID | bound by Pocket ID subject in `social_auth_usersocialauth`; unknown users are refused |
| qui | Pocket ID, `admins` group | |
| Sonarr, Radarr, Prowlarr | Tinyauth, `admins` | External authentication; API calls with a key skip the gate |
| Bazarr, qBittorrent, AdGuard, SigNoz, OpenSEO, Windows viewer | Tinyauth, `admins` | their own logins stay where they have one; SigNoz's API key and OpenSEO's `/mcp` skip the gate |
| Seerr | Tinyauth, `media` | no OIDC release yet; its Jellyfin login stays behind the gate, API calls with a key skip it |
| Worm fleet dashboard (`worm.rida.sh`) | its own passkeys, no Tinyauth | tailnet only; Caddy proxies to `tailscale serve` on mini-worm port 4470, so a second gate would only break its passkey ceremony and event stream |

A request skips the gate only when it carries an API key and targets an API path, so a bogus key reaches the app's own key check and nothing else. Port 8006 stays open on the LAN as 0007 decided; `windows.rida.sh` is the gated way in.
