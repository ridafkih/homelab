# 0002. Secrets: one sops file, a key table and per-app env files

## Context

On Arch the whole `.env` went to several containers and secrets were interpolated straight into Compose fields. The repo is public, so real values may only enter it encrypted, and each container should get only the secrets it uses.

## Decision

- `secrets/homelab.yaml` holds the production values, encrypted with sops to two age recipients: the host key and an admin key. `.sops.yaml` holds only public recipients.
- `secrets/vm.yaml` holds dummy values encrypted to `secrets/test-age.key`, a throwaway key committed on purpose for VM tests. It decrypts nothing else.
- `secrets/keys.tsv` is the single key table: `<template> <envKey> <secret> <empty>` per line, tab-separated, no header. `template` is a rendered env file such as `caddy.env` (or `-`), `envKey` is the name the container reads, `secret` is the sops path `<consumer>/<KEY>`, and `empty` is `deny` or `allow`. Nix and the shell tools both read it.
- `modules/secrets.nix` declares one sops secret per unique path and one sops template per env file, rendered as `KEY='value'` lines (mode 0400) under `/run/secrets/rendered`. Single quotes keep a `$` in the AdGuard bcrypt hash literal. It exposes `homelab.secrets.sopsFile`, `envDir`, `templates` and `resticPasswordFile`.
- The host decrypts with `/var/lib/sops-nix/key.txt`. Tests install the test key at that path through an activation script, the way sops-nix's own tests do.
- Both private keys are kept in 1Password (`homelab sops host age key`, `homelab sops admin age key`). `tests/secrets-age-keys.sh <vault> <token-file> <admin-key-file>` checks that the items exist and match `.sops.yaml` without printing them.
- `HF_TOKEN`, `OLLAMA_*` and `PIHOLE_*` are never present; an eval assertion enforces it.
- `.gitleaks.toml` extends the default rules and allowlists only `secrets/test-age.key`.

## Consequences

- Compose reads secrets only as `env_file: ${HOMELAB_SECRETS_DIR:?}/<template>`. OpenSEO is the one exception: its upstream file renames secrets through interpolation, so its rendered file is passed as a project `--env-file`.
- The public repo shows ciphertext, key names, public recipients and the test key. None of them decrypts a real value.
- Adding a secret means a row in `keys.tsv`, the value in `secrets/homelab.yaml`, and a dummy in `secrets/vm.yaml`, in one commit.
