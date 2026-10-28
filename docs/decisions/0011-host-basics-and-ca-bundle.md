# 0011. smartd, the journald cap and the container CA bundle

## Context

Arch had smartd, a 1 GB journald cap, an eMudhra CA blocklist, and a pacman hook that refreshed a CA bundle some containers mount over `/etc/ssl/certs`.

## Decision

- `modules/monitoring.nix`: smartd on the four disks by id, with Arch's flags and schedule and no notifiers; journald capped at 1 GB.
- `modules/trust.nix`: `/etc/homelab-ca/certs/ca-certificates.crt` is a bundle without trust rules, built from the NixOS CA bundle. NixOS 26.05 already distrusts the eMudhra roots, so no blocklist ships. `homelab.trust.bundleSource` is its store path, which changes whenever the bundle does, so `homelab-compose` restarts on a CA change.
- Containers mount `/etc/homelab-ca/certs:/etc/ssl/certs:ro`, as on Arch.

## Consequences

- `tests/host-basics.nix` checks that the eMudhra "EM DV TLS CA - G3B" intermediate fails against the host bundle, and, as a positive control, that it does verify against the AAA Certificate Services root alone, with the time pinned so the check doesn't drift.
