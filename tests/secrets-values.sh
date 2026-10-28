#!/usr/bin/env bash
set -euo pipefail
set +x

: "${SOPS_AGE_KEY_FILE:?set SOPS_AGE_KEY_FILE to the admin age key}"
test -s "$SOPS_AGE_KEY_FILE" || { echo "SOPS_AGE_KEY_FILE is missing or empty"; exit 2; }

for tool in git sops jq diff; do
  command -v "$tool" > /dev/null || { echo "missing tool: $tool"; exit 2; }
done

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

production=secrets/homelab.yaml
table=secrets/keys.tsv
non_credential_names='adguard/ADGUARD_USER authentik/AUTHENTIK_POSTGRESQL__USER grafana/GRAFANA_ADMIN_USER openseo/STORAGE_ACCESS_KEY'

ran=0
failures=0
pass() { ran=$((ran + 1)); }
fail() { ran=$((ran + 1)); failures=$((failures + 1)); echo "FAIL: $1"; }
finish() {
  echo "$ran checks, $failures failed"
  [ "$failures" -eq 0 ]
}

test -f "$production" || { fail "$production is missing"; finish; exit 1; }
pass
[ -n "$(git ls-files -- "$production")" ] && pass || fail "$production is not tracked"

if [ -f hosts/homelab/secrets.nix ] && grep -qF '../../secrets/homelab.yaml' hosts/homelab/secrets.nix; then
  pass
else
  fail "hosts/homelab/secrets.nix must set homelab.secrets.sopsFile to ../../secrets/homelab.yaml"
fi

[ -x migration/migrate-secrets.sh ] && pass || fail "migration/migrate-secrets.sh is missing or not executable"
if [ -f migration/migrate-secrets.sh ]; then
  bash -n migration/migrate-secrets.sh && pass || fail "migration/migrate-secrets.sh has a syntax error"
  if grep -nE '^[[:space:]]*#' migration/migrate-secrets.sh | grep -v '^1:#!' > /dev/null; then
    fail "migration/migrate-secrets.sh has comments"
  else
    pass
  fi
fi

recipient_of() {
  grep -E "^[[:space:]]*- &$1 age1" .sops.yaml | sed -E 's/.*(age1[0-9a-z]+).*/\1/'
}
expected_recipients=$(printf '%s\n%s\n' "$(recipient_of host)" "$(recipient_of admin)" | LC_ALL=C sort)
actual_recipients=$(grep -oE 'recipient: age1[0-9a-z]+' "$production" | sed 's/recipient: //' | LC_ALL=C sort)
[ "$actual_recipients" = "$expected_recipients" ] && pass || fail "$production must be encrypted to exactly the host and admin recipients"

decrypted() {
  sops -d --output-type json "$production"
}

if ! decrypted > /dev/null 2>&1; then
  fail "the admin key cannot decrypt $production"
  finish
  exit 1
fi
pass

expected_paths=$(cut -f3 "$table" | LC_ALL=C sort -u)
actual_paths=$(decrypted | jq -r 'paths(scalars) | map(tostring) | join("/")' | LC_ALL=C sort)
if [ "$actual_paths" = "$expected_paths" ]; then
  pass
else
  fail "decrypted key paths differ from secrets/keys.tsv:"
  diff <(echo "$expected_paths") <(echo "$actual_paths") | grep -E '^[<>]' || true
fi

expected_empty=$(awk -F'\t' '$4 == "allow" { print $3 }' "$table" | LC_ALL=C sort -u)
actual_empty=$(decrypted | jq -r '[paths(scalars) as $p | select(getpath($p) == "") | $p | map(tostring) | join("/")] | .[]' | LC_ALL=C sort)
extra_empty=$(LC_ALL=C comm -13 <(echo "$expected_empty") <(echo "$actual_empty") | grep . || true)
[ -z "$extra_empty" ] && pass || fail "empty values not allowed by secrets/keys.tsv: $(echo "$extra_empty" | tr "\n" " ")"

bad_shape=$(decrypted | jq -r '([39] | implode) as $quote | [paths(scalars) as $p | getpath($p) as $v | select(($v | type) != "string" or ($v | contains($quote)) or ($v | contains("\n"))) | $p | map(tostring) | join("/")] | .[]')
[ -z "$bad_shape" ] && pass || fail "values that are not strings or hold a single quote or newline (0002): $(echo "$bad_shape" | tr "\n" " ")"

leak_patterns() {
  decrypted | jq -r --arg skip "$non_credential_names" '
    ($skip | split(" ")) as $skipped
    | [paths(scalars) as $p | {name: ($p | map(tostring) | join("/")), value: getpath($p)}]
    | .[] | select(.value != "" and (.name as $n | $skipped | index($n) | not)) | .value'
}

tree_hits=$({ git grep -F -l -f <(leak_patterns) -- . ':!secrets/homelab.yaml' 2> /dev/null || true; } | wc -l | tr -d ' ')
[ "$tree_hits" = 0 ] && pass || fail "plaintext secret values found in $tree_hits tracked files"

history_hits=$(git log -p --all -- . ':!secrets/homelab.yaml' | { grep -F -c -f <(leak_patterns) || true; })
[ "$history_hits" = 0 ] && pass || fail "plaintext secret values found on $history_hits lines of history"

echo "skipped by name in the leak scan: $non_credential_names"
finish
