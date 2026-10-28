# 0013. What may be public in this repo

## Context

The repo is public. An audit of every ref, the full history, and issues found no secret ever pushed, but every new file adds surface.

## Decision

- Fine to be public: the domain `rida.sh` and its subdomains, the host name `homelab`, the user `rida`, the LAN address 10.0.0.98 and private ranges, Docker subnets, Cloudflare's published prefixes, Tailscale's generic IPv6 range, disk UUIDs and drive serials, image digests, sops ciphertext, key names, age public recipients, and the throwaway test key with `secrets/vm.yaml`.
- Never in the repo: secret values or private keys other than the test key, the tailnet's domain, email addresses, the machine-id, MAC addresses, the DHCP DUID, the real IPv6 prefix, password manager vault IDs, Mullvad account details, local home-directory paths, `docker inspect` output, rendered env files, and notes about the tooling that wrote this repo.
- `.gitignore` keeps `.env` files, hand backups (`*.before-*`, `*.bak`), Nix `result` links and disk images out.
- `tests/exposure.sh` scans every file for the never-list (emails, tailnet names, home paths, MAC addresses, key paths, build-agent notes) and for shell `${VAR:-default}` fallbacks; it runs in `nix flake check`. `tests/secrets-repo.sh` scans the whole history with gitleaks and trufflehog and checks that the only age identity ever committed is the test key; it runs in CI.

## Consequences

- An unused Hugging Face token lived only in the box's untracked `.env`. It was never pushed and is not carried over; revoking it is a precaution.
