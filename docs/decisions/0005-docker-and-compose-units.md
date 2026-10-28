# 0005. Docker and the systemd units that run the Compose projects

## Context

The apps stay on Docker Compose. NixOS needs units that start the three projects after Docker, the mounts and the secrets, react to secret and CA bundle changes, and don't need a registry or a working exit node to start.

## Decision

- Docker 29 (`pkgs.docker_29`), data root `/var/lib/docker`, overlay2, json-file logs at 10 MB times 3, no auto-prune.
- The Docker daemon has no `dns` key (0007) and no `runtimes` key (0009).
- docker0 is pinned with `bip = 172.17.0.1/16`. Caddy reaches host services through `CADDY_HOST_MACHINE_HOSTNAME`, which is `172.17.0.1` in `homelab.env`; an eval assertion fails the build if the two ever differ.
- `default-address-pools` hands out `172.17.0.0/16`, `172.18.0.0/16`, `172.21.0.0/16` to `172.31.0.0/16` and `192.168.0.0/16` (as /20s), and skips `172.19.0.0/16` and `172.20.0.0/16`. Those two belong to `authentik-network` and `homelab-network`, which declare fixed subnets, so a fresh Docker never gives their range to another network first. Every pool is a connected route on the box, which the egress policy's `suppress_prefixlength 0` rule relies on (0006).
- Units `homelab-compose`, `openseo-compose` and `windows-compose`: oneshot with `RemainAfterExit`, after and requiring `docker.service`, wanting `network-online.target`, `RequiresMountsFor` `/data` and the checkout, `AssertPathExists` on every env file they pass, and `docker compose ... up -d --pull missing --remove-orphans` for start and reload, `down` for stop. Start timeout 1 hour, stop timeout 5 minutes.
- `openseo-compose` comes after and requires `homelab-compose`, because it joins `homelab_homelab-network`.
- A change to a rendered env file reloads the project that reads it. A CA bundle change restarts `homelab-compose`.
- `homelab.compose.extraFiles` and `homelab.compose.services` let tests and the test VM layer override files and limit the services; production sets neither.
- A tmpfiles rule creates `.data`, `jellyfin/{config,cache}` and `jellyseerr/config` under it, owned by the user. Jellyfin and Jellyseerr run as uid 1000, and Docker would otherwise create a missing bind source as root and leave them crash-looping on a fresh box.

## Consequences

- Images only change through digest bumps (0004). The first start after cutover needs the images loaded or a working exit node.
- `--remove-orphans` deletes containers not in git, so the runbook compares `docker compose ps -a` with the tree before the first start.
