# Migration

Tools and checks for moving the box from Arch to NixOS. None of this is needed once the box runs NixOS: step 4 of the cutover runbook's [cleanup](../docs/cutover.md#cleanup) deletes this directory.

- `build-host.md`: how the live Arch box builds and tests the flake until cutover.
- `compose-diff.sh <project> <old-path> <new-file>`: renders a Compose file from the last Arch-era commit (`9af811a`) and its NixOS-era replacement with dummy values, and diffs them. Exit 0 identical, 1 different, 2 error.
- `migrate-secrets.sh`: copies the live `.env` values into `secrets/homelab.yaml` without printing them (cutover step 6).

## Checks

These need the Arch-era history, the live box or tools that only exist on the build host, so `nix flake check` doesn't run them. Run them from the repo root:

| Check | Needs |
| --- | --- |
| `sh migration/tests/compose-diff.sh` | docker-compose, jq, git history back to 9af811a |
| `sh migration/tests/compose-edge.sh`, `compose-media.sh`, `compose-dns-ai.sh`, `compose-openseo.sh`, `compose-seafile.sh` | the same, plus gitleaks for some |
| `sh migration/tests/compose-observability.sh [--live <build-host>]` | the same; `--live` compares with the running containers |
| `sh migration/tests/compose-windows.sh [inspect.json [repo-digests.json]]` | docker-compose, jq; optional `docker inspect` captures from the box |
| `sh migration/tests/compose-edge-caddy.sh ssh <build-host>` | ssh to the build host, to validate the Caddyfile with the pinned Caddy |
| `bash migration/tests/migrate-secrets.sh` | the build host: nix, sops, age, passwordless sudo |
| `bash migration/tests/retire-arch.sh` | git history back to 9af811a |
| `bash migration/tests/cutover-docs.sh` | nothing beyond coreutils, gawk and gitleaks |
| `bash migration/tests/ci-workflow.sh` | docker, for actionlint |
| `sh migration/tests/build-host-doc.sh` | nothing |
| `sh migration/tests/build-host-live.sh <evidence-dir> ssh <build-host>` | ssh to the build host and the snapshots taken before Nix was installed |
