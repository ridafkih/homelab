#!/usr/bin/env bash
set -euo pipefail

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

workflow=.github/workflows/nix.yml
actionlint_image=rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667

failures=0

fail() {
  echo "FAIL: $1"
  failures=$((failures + 1))
}

pass() {
  echo "ok: $1"
}

expect_match() {
  if grep -qE -- "$2" "$workflow"; then pass "$1"; else fail "$1"; fi
}

expect_absent() {
  if grep -nE -- "$2" "$workflow"; then fail "$1"; else pass "$1"; fi
}

if [ ! -f "$workflow" ]; then
  echo "FAIL: $workflow does not exist"
  exit 1
fi

if docker run --rm -i "$actionlint_image" -color -stdin-filename "$workflow" - <"$workflow"; then
  pass "actionlint"
else
  fail "actionlint"
fi

expect_match "workflow is named nix" '^name:[[:space:]]*nix[[:space:]]*$'
expect_match "push trigger" '^[[:space:]]+push:'
expect_match "push branches include nixos" '(\[|,|-)[[:space:]]*nixos[[:space:]]*(,|\]|$)'
expect_match "push branches include main" '(\[|,|-)[[:space:]]*main[[:space:]]*(,|\]|$)'
expect_match "manual dispatch" 'workflow_dispatch'
expect_absent "no pull_request triggers" 'pull_request'
expect_absent "no secrets references" 'secrets\.'
expect_absent "no write permissions" ':[[:space:]]*write'
expect_absent "no write-all permissions" 'write-all'
expect_match "top-level contents read permission" '^[[:space:]]+contents:[[:space:]]*read'
expect_match "permissions block" '^permissions:'
expect_match "runs on ubuntu-latest" 'runs-on:[[:space:]]*ubuntu-latest'
expect_match "job timeout set" 'timeout-minutes:[[:space:]]*[0-9]+'
expect_match "concurrency group" '^concurrency:'

uses_lines=$(grep -E '^[[:space:]]*(-[[:space:]]+)?uses:' "$workflow" || true)
if [ -z "$uses_lines" ]; then
  fail "workflow uses actions"
else
  unpinned=$(echo "$uses_lines" | grep -vE 'uses:[[:space:]]*[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[A-Za-z0-9_./-]+)?@[0-9a-f]{40}([[:space:]]+#.*)?$' || true)
  if [ -n "$unpinned" ]; then
    echo "$unpinned"
    fail "every action pinned by full SHA"
  else
    pass "every action pinned by full SHA"
  fi
fi
expect_match "uses actions/checkout" 'uses:[[:space:]]*actions/checkout@'
expect_match "uses cachix/install-nix-action" 'uses:[[:space:]]*cachix/install-nix-action@'
expect_match "checkout does not persist credentials" 'persist-credentials:[[:space:]]*false'
expect_absent "no third-party disk cleanup action" 'uses:.*(free-disk-space|maximize-build-space|nothing-but-nix)'
expect_absent "no binary cache services" 'cachix/cachix-action|magic-nix-cache|flakehub'

expect_match "frees disk before building" 'rm -rf.*(/usr/share/dotnet|/usr/local/lib/android|/opt/ghc|/opt/hostedtoolcache)'
expect_match "logs free disk" 'df -h'
expect_match "flakes enabled" 'experimental-features[[:space:]]*=[[:space:]]*nix-command flakes'
expect_match "flake config not accepted" 'accept-flake-config[[:space:]]*=[[:space:]]*false'

expect_match "flake check without build" 'nix flake check.*--no-build'
expect_match "builds the homelab toplevel" "nix build.*nixosConfigurations\\.homelab\\.config\\.system\\.build\\.toplevel"
expect_match "logs closure size" 'nix path-info.*-S'

lock_flags=$(grep -c -- '--no-update-lock-file' "$workflow" || true)
if [ "$lock_flags" -ge 2 ]; then pass "lock file never updated ($lock_flags)"; else fail "--no-update-lock-file on both nix commands (found $lock_flags)"; fi

expect_absent "no NIXPKGS_ALLOW_UNFREE" 'NIXPKGS_ALLOW_UNFREE'
expect_absent "no --impure" '--impure'
expect_absent "no deploy" 'nixos-rebuild|switch-to-configuration|deploy-rs|colmena|ssh '
expect_absent "no setup actions after toolcache removal" 'uses:[[:space:]]*actions/setup-'

if gitleaks dir --no-banner --redact "$workflow" >/dev/null 2>&1; then
  pass "gitleaks"
else
  fail "gitleaks"
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
