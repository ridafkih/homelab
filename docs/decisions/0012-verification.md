# 0012. How the config is verified before cutover

## Context

The configuration has to be proven before the downtime window, without disturbing the Arch box that is still serving.

## Decision

- `nix flake check` runs the eval checks, the NixOS VM tests (egress, backups, Compose, storage, DNS and firewall, secrets, host basics), the sandboxed shell suites and the host build.
- `scripts/vm-smoke.sh core|media|obs` boots the real host as a VM (6 GB, 4 cores, a 40 GB disk, two empty data disks) with the GPU and egress policy off, test secrets, a `tls internal` Caddyfile and one tier of containers, and checks that every container is healthy and every Caddy route answers. The core tier also runs the database dumps (0010). Each boot runs under a 7 GB memory cap at the lowest CPU and IO priority, and the script refuses to run inside the live checkout and checks that no live container or socket changed.
- Nothing VM-only reaches the production build; `tests/vm-smoke.nix` checks this.
- CI (`.github/workflows/nix.yml`) scans the history for secrets (`tests/secrets-repo.sh`), evaluates the flake, runs the checks that need no VM, and builds the host. It has no secrets and read-only permissions.
- `tests/secrets-values.sh` (needs the admin age key) and `tests/secrets-age-keys.sh` (needs 1Password) run by hand.

## Consequences

- The Windows VM needs nested KVM and is checked only at cutover.
- The cloudflared tunnels and the Grafana funnel can't connect with dummy tokens, so the smoke run expects them to fail.
