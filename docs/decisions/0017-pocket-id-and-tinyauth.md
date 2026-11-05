# 0017. Pocket ID for sign-in, Tinyauth in front of apps without OIDC

## Context

Authentik (four containers and its own Cloudflare tunnel) only served Tailscale's custom OIDC login. Every app behind Caddy kept its own login. The goal is one passkey sign-in for everything.

## Decision

- Pocket ID runs on the host from the nixpkgs module (`modules/sso.nix`), on port 1411, at `https://id.rida.sh`. Its encryption key and static API key are sops secrets loaded as systemd credentials.
- `id.rida.sh` is public, because Tailscale's control plane fetches discovery, keys and tokens from it. The `rida.sh` Cloudflare tunnel carries it: the tunnel's remote config routes `id.rida.sh` to `http://rida.sh-bun` (Caddy's plain-HTTP side), and Caddy's `http://id.rida.sh` site proxies to Pocket ID. That route and its proxied CNAME live in Cloudflare, not in this repo.
- Containers that talk to Pocket ID server-side resolve `id.rida.sh` to Caddy through a network alias on `homelab-network`, so they never leave the box.
- Groups and OIDC clients are declared in `modules/sso.nix`. `pocket-id-provision` applies them through the API on every switch: it creates what is missing, updates what drifted and sets each confidential client's secret from sops. Users, their passkeys and their group memberships are state in Pocket ID's database, not config; `pocket-id-invite` creates a user and prints a one-time sign-in link.
- Tinyauth runs on the host on port 3820 at `https://auth.rida.sh`, signs in only through Pocket ID, and answers Caddy's `forward_auth` for apps without OIDC. Its app rules (domain and required group) are declared in the same module; anything not listed is denied.
- The firewall accepts ports 1411 and 3820 only from `homelab-network` (`172.20.0.0/16`), where Caddy is.
- Pocket ID's SQLite database is dumped nightly with `.backup`, and both state directories are in the restic paths.

## Consequences

- Passkeys are bound to `id.rida.sh`; changing that host loses every registered passkey.
- Losing Pocket ID locks out every app's SSO path, so each app keeps a local admin login until its SSO is proven.
