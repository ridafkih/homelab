# 0003. Compose layout and the lint rules

## Context

`compose.yaml` was one 700-line file, with OpenSEO as a separate project in `openseo/` and the Windows VM outside git. Cutover has to keep every project, container, volume and network name so existing data reattaches.

## Decision

- The root `compose.yaml` sets `name: homelab`, includes `apps/{caddy,authentik,ridash,jellyfin,media,seafile,observability,adguard,open-webui}/compose.yaml`, and is the only place `homelab-network` (bridge, `172.20.0.0/16`) is declared.
- Each app has its own folder with its config files next to its Compose file. App-private networks are declared once, in the app that owns them (`authentik-network` keeps `172.19.0.0/16`, which OpenSEO's `remote_ip` guard trusts).
- `apps/openseo` (`name: openseo`) and `apps/windows` (`name: windows`) are standalone projects; OpenSEO joins `homelab_homelab-network` as an external network.
- `homelab.env` holds the non-secret settings shared by the apps, as literal values: host and database names, `CADDY_DOMAIN`, `CADDY_HOST_MACHINE_HOSTNAME`, `HOMELAB_DATA_DIR`, `HOMELAB_SECRETS_DIR`, `PROMETHEUS_RETENTION`, `SEAFILE_DATA_PATH`. No key in it is also in `secrets/keys.tsv`.
- Authentik's `.authentik/` binds move under `.data/authentik/`. The macvlan `local-network` is gone (0006).
- `scripts/compose-lint.sh` enforces, on every Compose file: interpolation only as `${VAR:?}` or `${VAR?}`; no secret names interpolated (except OpenSEO's, with `--secret-env openseo.env`); every image pinned by digest and no `build:`; volume sources that are named volumes, absolute paths, `${HOMELAB_DATA_DIR:?}/...` or `./` paths that stay inside the folder and out of `.data`; `env_file` entries only from the rendered secrets directory; included files never set `name:` or redeclare `homelab-network`; each network declared once.

## Consequences

- `tests/compose-lint.sh` covers the lint rules and the include tree, and runs in `nix flake check`.
- The NixOS tree must never be checked out on the Arch box before cutover: `up --remove-orphans` there would remove containers the old tree still runs.
