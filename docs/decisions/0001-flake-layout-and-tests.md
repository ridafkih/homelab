# 0001. Flake layout, shared options and how tests are found

## Context

The repo used to be one large `compose.yaml`, an Arch `host/` tree, a `config/` folder and a Makefile. The NixOS configuration needs one obvious place for each kind of file, and adding a module or a test should not mean editing a central list.

## Decision

A plain flake, no flake-parts.

- Inputs: `nixpkgs` (`nixos-26.05`), `sops-nix` and `disko`, both following nixpkgs. `flake.lock` is committed.
- `nixosConfigurations.homelab` is built from `hosts/homelab/default.nix`, which imports every `*.nix` in `hosts/homelab/` and `modules/`, plus the sops-nix and disko modules. Adding a module means adding a file.
- `checks.x86_64-linux` has one check per regular `tests/<name>.nix`, plus `toplevel`, the host build. A test file is `{ pkgs, self, lib }: <derivation>`; `tests/fixtures/` holds test data and is not scanned. `tests/toplevel.nix` is reserved.
- `tests/shell-suites.nix` runs the shell suites that need no network, secrets or git history (`compose-lint.sh`, `exposure.sh`, `gitignore.sh`, `readme-restore.sh`) inside the sandbox. Every other `tests/*.sh` must be named there as run outside the sandbox, or evaluation fails, so no shell test can sit unrun.
- Shared options live in `modules/options.nix`: `homelab.user`, `uid`, `gid`, `checkoutDir`, `dataDir`, `lan.interface`, `cloudflareTunnelEdge.ipv4`/`ipv6`, `gpu.enable` and `unfreeAllow`. Options that belong to one concern are declared in that module (`homelab.secrets.*`, `homelab.compose.*`, `homelab.egress.enable`, `homelab.trust.*`).
- `checkoutDir` and `dataDir` are strings, never Nix paths, so `.data` can never be copied into the store.
- Unfree packages are allowed by name through `homelab.unfreeAllow` only. There is no `NIXPKGS_ALLOW_UNFREE` and no `--impure`.
- `boot.loader.systemd-boot.enable = true` is a plain definition; disko owns the file systems.
- Code style: no comments in Nix or shell, and no `${VAR:-default}` fallbacks anywhere. Missing configuration fails at once.

## Consequences

- `nix flake check` evaluates every check; `nix flake check` without `--no-build` also runs the VM tests, which need KVM.
- Tooling that only matters before cutover lives in `migration/` and goes away afterwards (0014).
