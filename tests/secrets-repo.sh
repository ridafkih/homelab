#!/usr/bin/env bash
set -euo pipefail

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

for tool in git gitleaks sops age-keygen jq; do
  command -v "$tool" > /dev/null || { echo "missing tool: $tool"; exit 1; }
done

failures=0
fail() {
  echo "$1"
  failures=$((failures + 1))
}

identity_pattern='AGE-SECRET-KEY-1[0-9A-Z]{50,}'
holders=$(git grep -lE "$identity_pattern" HEAD -- . | sed 's/^HEAD://' || true)
[ "$holders" = "secrets/test-age.key" ] || fail "age identities must be only in secrets/test-age.key, found in: [$holders]"

test -f .gitleaks.toml || fail "missing .gitleaks.toml"
if test -f .gitleaks.toml; then
  grep -qE '^\[extend\]' .gitleaks.toml || fail ".gitleaks.toml must extend the default rules"
  grep -qE 'useDefault *= *true' .gitleaks.toml || fail ".gitleaks.toml must use the default rules"
fi
test -e .gitleaksignore && fail ".gitleaksignore fingerprints break on rebase; use the .gitleaks.toml path allowlist"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

gitleaks git --redact --no-banner --exit-code 1 --report-path "$scratch/git.json" . > /dev/null 2>&1 \
  || fail "gitleaks git found leaks (redacted report: $(jq -r '[.[] | .File + ":" + .RuleID] | join(" ")' "$scratch/git.json" 2>/dev/null))"
gitleaks dir --redact --no-banner --exit-code 1 --report-path "$scratch/dir.json" . > /dev/null 2>&1 \
  || fail "gitleaks dir found leaks (redacted report: $(jq -r '[.[] | .File + ":" + .RuleID] | join(" ")' "$scratch/dir.json" 2>/dev/null))"

if test -f secrets/test-age.key && test -f .gitleaks.toml; then
  scan_control() {
    rm -rf "$scratch/control"
    mkdir -p "$scratch/control/$(dirname "$1")"
    cp .gitleaks.toml "$scratch/control/.gitleaks.toml"
    cp secrets/test-age.key "$scratch/control/$1"
    (cd "$scratch/control" && gitleaks dir --redact --no-banner --exit-code 1 --config .gitleaks.toml . > /dev/null 2>&1)
  }
  scan_control secrets/test-age.key || fail "gitleaks flags secrets/test-age.key despite the allowlist"
  scan_control secrets/other-age.key && fail "gitleaks allowlist is too wide: a key at secrets/other-age.key passes"
  scan_control elsewhere/test-age.key && fail "gitleaks allowlist is too wide: a key at elsewhere/test-age.key passes"
fi

expected_paths=$(cut -f3 secrets/keys.tsv | LC_ALL=C sort -u)
actual_paths=$(SOPS_AGE_KEY_FILE=secrets/test-age.key sops -d --output-type json secrets/vm.yaml \
  | jq -r 'paths(scalars) | map(tostring) | join("/")' | LC_ALL=C sort)
[ "$actual_paths" = "$expected_paths" ] || fail "decrypted secrets/vm.yaml key paths differ from secrets/keys.tsv"
if echo "$actual_paths" | grep -qE 'HF_TOKEN|OLLAMA|PIHOLE'; then
  fail "secrets/vm.yaml holds a forbidden key"
fi

if test -f secrets/homelab.yaml; then
  if SOPS_AGE_KEY_FILE=secrets/test-age.key sops -d secrets/homelab.yaml > /dev/null 2>&1; then
    fail "the test key decrypts secrets/homelab.yaml"
  fi
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures secrets repo checks failed"
  exit 1
fi
echo "ok: secrets repo checks passed"
