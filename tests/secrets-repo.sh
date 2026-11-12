#!/usr/bin/env bash
set -euo pipefail

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

for tool in git gitleaks trufflehog sops age-keygen jq; do
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

tracked=$(git ls-files)
grep -Eq '(^|/)\.env(\..*)?$|(^|/)\.envrc$|\.before-|\.bak$|\.qcow2$|(^|/)result(-[^/]*)?$' <<< "$tracked" \
  && fail "env files, hand backups, disk images or build outputs are tracked"
grep -q 'machine-id$' <<< "$tracked" && fail "a machine-id is tracked"

age_identity='AGE-SECRET-KEY-1[A-Z0-9]{50,}'
identity_paths=$(git log --format= --name-only -E -G"$age_identity" HEAD | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//')
[ "$identity_paths" = "secrets/test-age.key" ] || fail "age identities in history must live only in secrets/test-age.key, found in: [$identity_paths]"
distinct_identities=$(git log -p --format= HEAD | grep -oE "$age_identity" | sort -u | wc -l | tr -d ' ')
[ "$distinct_identities" = 1 ] || fail "history holds $distinct_identities distinct age identities, expected only the test key"

test_recipient=$(sed -nE 's/^  - &test (age1[0-9a-z]+)$/\1/p' .sops.yaml)
[ "$(age-keygen -y secrets/test-age.key 2>/dev/null)" = "$test_recipient" ] || fail "secrets/test-age.key is not the &test recipient in .sops.yaml"
recipients_of() {
  sed -nE 's/^ +recipient: (age1[0-9a-z]+)$/\1/p' "$1" | sort | tr '\n' ' ' | sed 's/ $//'
}
expected_recipients=$(sed -nE 's/^  - &(host|admin) (age1[0-9a-z]+)$/\2/p' .sops.yaml | sort | tr '\n' ' ' | sed 's/ $//')
[ "$(recipients_of secrets/homelab.yaml)" = "$expected_recipients" ] || fail "secrets/homelab.yaml is not encrypted to exactly the host and admin keys"
[ "$(recipients_of secrets/vm.yaml)" = "$test_recipient" ] || fail "secrets/vm.yaml is not encrypted to the test key alone"

leaf_kinds() {
  awk '
    /^sops:/ { exit }
    /^[[:space:]]*(#|$)/ { next }
    {
      match($0, /^ */); depth = RLENGTH / 4
      line = substr($0, RLENGTH + 1)
      key = line; sub(/:.*/, "", key)
      value = line; sub(/^[^:]*:[[:space:]]*/, "", value)
      path[depth] = key
      if (value == "") next
      full = path[0]; for (i = 1; i <= depth; i++) full = full "/" path[i]
      if (value ~ /^ENC\[AES256_GCM,data:.*,type:[a-z]+\]$/) kind = "enc"
      else if (value == "\"\"") kind = "empty"
      else kind = "plain"
      print full "\t" kind
    }
  ' "$1"
}
empty_allowed=$(awk -F '\t' '$4 == "allow" { print $3 }' secrets/keys.tsv | sort -u)
for file in secrets/homelab.yaml secrets/vm.yaml; do
  leaves=$(leaf_kinds "$file")
  [ -n "$leaves" ] || fail "$file has no values"
  plain=$(awk -F '\t' '$2 == "plain" { print $1 }' <<< "$leaves" | tr '\n' ' ')
  [ -z "$plain" ] || fail "$file has plaintext values: $plain"
  bad_empty=$(awk -F '\t' '$2 == "empty" { print $1 }' <<< "$leaves" | grep -vxF -f <(printf '%s\n' "$empty_allowed") | tr '\n' ' ' || true)
  [ -z "$bad_empty" ] || fail "$file leaves keys empty that keys.tsv does not allow: $bad_empty"
done

git log -p --format= HEAD -- . ':!tests' ':!migration' ':!scripts/tests' ':!docs/decisions' > "$scratch/history.patch"
grep -qE '^\+.*-----BEGIN [A-Z ]*PRIVATE KEY-----' "$scratch/history.patch" && fail "a PEM private key is in history"
grep -qE '^\+.*hf_[A-Za-z0-9]{30,}' "$scratch/history.patch" && fail "a Hugging Face token is in history"

no_update=(--no-update)
mkdir "$scratch/empty"
case $(trufflehog filesystem --no-update --json "$scratch/empty" 2>&1 > /dev/null || true) in
  *"cannot be repeated"*) no_update=() ;;
esac
trufflehog git "file://$PWD" "${no_update[@]}" --json --results=verified,unverified,unknown > "$scratch/trufflehog.json" 2> "$scratch/trufflehog.err" \
  || fail "trufflehog could not scan the history: $(tail -n 1 "$scratch/trufflehog.err")"
found=$(jq -c 'select(.SourceMetadata != null) | {d: .DetectorName, f: .SourceMetadata.Data.Git.file, c: .SourceMetadata.Data.Git.commit[0:8]}' "$scratch/trufflehog.json")
[ -z "$found" ] || fail "trufflehog found secrets in history: $found"

if [ "$failures" -ne 0 ]; then
  echo "$failures secrets repo checks failed"
  exit 1
fi
echo "ok: secrets repo checks passed"
