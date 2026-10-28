#!/usr/bin/env bash
set -euo pipefail

for tool in git nix sops age-keygen jq sudo diff; do
  command -v "$tool" > /dev/null || { echo "missing tool: $tool"; exit 2; }
done
sudo -n true 2> /dev/null || { echo "needs passwordless sudo for the restic file descriptor"; exit 2; }

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
scratch=$(mktemp -d -t migrate-secrets.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

sentinel=qz7
copy="$scratch/repo"
fixtures="$scratch/fixtures"
empty_tmp="$scratch/tmp"
mkdir -p "$copy" "$fixtures" "$empty_tmp"

git -C "$repo" ls-files -co --exclude-standard -z | (cd "$repo" && tar -cf - --null -T -) | tar -xf - -C "$copy"
rm -f "$copy/secrets/homelab.yaml" "$copy/hosts/homelab/secrets.nix"

age-keygen -o "$scratch/age.key" 2> /dev/null
throwaway_recipient=$(age-keygen -y "$scratch/age.key")
cat > "$copy/.sops.yaml" << EOF
creation_rules:
  - path_regex: ^secrets/homelab\.yaml\$
    key_groups:
      - age:
          - $throwaway_recipient
EOF

(
  cd "$copy"
  git init -q
  git add -A
  git -c user.name=fixture -c user.email=fixture@invalid commit -q -m fixture
)

ran=0
failures=0
pass() { ran=$((ran + 1)); }
fail() { ran=$((ran + 1)); failures=$((failures + 1)); echo "FAIL: $1"; }

table="$copy/secrets/keys.tsv"
main_keys=$(cut -f3 "$table" | LC_ALL=C sort -u | grep -vE '^(openseo|restic)/' | cut -d/ -f2)
openseo_keys=$(cut -f3 "$table" | LC_ALL=C sort -u | grep -E '^openseo/' | cut -d/ -f2)

write_good_fixtures() {
  local key
  {
    echo "# fixture env"
    echo
    for key in $main_keys; do
      case "$key" in
        ADGUARD_PASSWORD_HASH) echo "ADGUARD_PASSWORD_HASH=\$\$2y\$\$10\$\$$sentinel.adguard/hash" ;;
        GRAFANA_ADMIN_PASSWORD) echo "GRAFANA_ADMIN_PASSWORD='$sentinel grafana \$literal'" ;;
        SEAFILE_JWT_PRIVATE_KEY) echo "SEAFILE_JWT_PRIVATE_KEY=\"$sentinel-jwt=with=equals\"" ;;
        GRAFANA_ADMIN_USER) echo "GRAFANA_ADMIN_USER=$sentinel-grafana-user # inline comment" ;;
        OTEL_AUTH_TOKEN) echo "OTEL_AUTH_TOKEN=$sentinel-otel#token" ;;
        TS_AUTHKEY) echo "export TS_AUTHKEY=$sentinel-ts-authkey" ;;
        *) echo "$key=$sentinel-$key" ;;
      esac
    done
    grep -vE '^\s*(#|$)' "$copy/homelab.env"
    echo "HF_TOKEN=$sentinel-hf"
    echo "OLLAMA_CONTEXT_LENGTH=8192"
    echo "PIHOLE_TZ=UTC"
    echo "PIHOLE_FTLCONF_WEBSERVER_API_PASSWORD=$sentinel-pihole"
    echo "SIGNOZ_VERSION=v0.0.0"
    echo "SIGNOZ_OTELCOL_VERSION=v0.0.0"
  } > "$fixtures/homelab.env"
  {
    for key in $openseo_keys; do
      if awk -F'\t' -v s="openseo/$key" '$3 == s && $4 == "allow" { found = 1 } END { exit !found }' "$table"; then
        echo "$key="
      else
        echo "$key=$sentinel-$key"
      fi
    done
    grep -vE '^\s*(#|$)' "$copy/apps/openseo/openseo.env"
  } > "$fixtures/openseo.env"
  printf '%s\n' "$sentinel-restic" > "$fixtures/restic.pass"
}

expected_json() {
  local key consumer value
  {
    for key in $main_keys; do
      consumer=$(cut -f3 "$table" | grep -E "/$key\$" | head -n1 | cut -d/ -f1)
      case "$key" in
        ADGUARD_PASSWORD_HASH) value="\$2y\$10\$$sentinel.adguard/hash" ;;
        GRAFANA_ADMIN_PASSWORD) value="$sentinel grafana \$literal" ;;
        SEAFILE_JWT_PRIVATE_KEY) value="$sentinel-jwt=with=equals" ;;
        GRAFANA_ADMIN_USER) value="$sentinel-grafana-user" ;;
        OTEL_AUTH_TOKEN) value="$sentinel-otel#token" ;;
        TS_AUTHKEY) value="$sentinel-ts-authkey" ;;
        *) value="$sentinel-$key" ;;
      esac
      jq -n --arg c "$consumer" --arg k "$key" --arg v "$value" '{($c): {($k): $v}}'
    done
    for key in $openseo_keys; do
      if awk -F'\t' -v s="openseo/$key" '$3 == s && $4 == "allow" { found = 1 } END { exit !found }' "$table"; then
        value=""
      else
        value="$sentinel-$key"
      fi
      jq -n --arg k "$key" --arg v "$value" '{openseo: {($k): $v}}'
    done
    jq -n --arg v "$sentinel-restic" '{restic: {RESTIC_PASSWORD: $v}}'
  } | jq -S -s 'reduce .[] as $item ({}; . * $item)'
}

run_script() {
  (cd "$copy" && TMPDIR="$empty_tmp" bash migration/migrate-secrets.sh "$@")
}

run_mode() {
  local mode=$1
  shift
  run_script "$mode" --env "$fixtures/homelab.env" --openseo-env "$fixtures/openseo.env" --restic-pass "$fixtures/restic.pass" "$@"
}

no_value_in() {
  if grep -qF "$sentinel" "$2"; then fail "$1 printed a secret value"; else pass; fi
}

write_good_fixtures

if run_mode --preflight > "$scratch/preflight.out" 2>&1; then
  pass
else
  fail "--preflight rejects a well-formed fixture: $(grep -v "$sentinel" "$scratch/preflight.out" | tail -n 5)"
fi
no_value_in "--preflight" "$scratch/preflight.out"

if run_mode --encrypt > "$scratch/encrypted.yaml" 2> "$scratch/encrypt.err"; then
  pass
else
  fail "--encrypt fails on a well-formed fixture: $(grep -v "$sentinel" "$scratch/encrypt.err" | tail -n 5)"
fi
no_value_in "--encrypt stdout" "$scratch/encrypted.yaml"
no_value_in "--encrypt stderr" "$scratch/encrypt.err"

if grep -q '^sops:' "$scratch/encrypted.yaml" && grep -qF "recipient: $throwaway_recipient" "$scratch/encrypted.yaml"; then
  pass
else
  fail "--encrypt output is not sops YAML for the .sops.yaml recipients"
fi

if SOPS_AGE_KEY_FILE="$scratch/age.key" sops -d --input-type yaml --output-type json "$scratch/encrypted.yaml" 2> /dev/null | jq -S . > "$scratch/actual.json"; then
  expected_json > "$scratch/expected.json"
  if diff -q "$scratch/expected.json" "$scratch/actual.json" > /dev/null; then
    pass
  else
    fail "decrypted values differ from the fixture at: $(jq -r --slurpfile e "$scratch/expected.json" '[paths(scalars) as $p | select(getpath($p) != ($e[0] | getpath($p))) | $p | join("/")] + [($e[0] | paths(scalars)) as $p | select(getpath($p) == null) | $p | join("/")] | unique | join(" ")' "$scratch/actual.json")"
  fi
else
  fail "--encrypt output does not decrypt with the .sops.yaml recipient's key"
fi

[ -z "$(ls -A "$empty_tmp")" ] && pass || fail "the script left files in TMPDIR"
[ -z "$(git -C "$copy" status --porcelain)" ] && pass || fail "the script changed the checkout: $(git -C "$copy" status --porcelain | tr '\n' ' ')"

expect_rejection() {
  local name=$1 wanted=$2
  write_good_fixtures
  "$3"
  if run_mode --preflight > "$scratch/reject.out" 2>&1; then
    fail "--preflight accepts $name"
  else
    pass
    if [ -n "$wanted" ]; then
      grep -qiF "$wanted" "$scratch/reject.out" && pass || fail "--preflight does not name $wanted for $name"
    fi
  fi
  no_value_in "--preflight on $name" "$scratch/reject.out"
  if run_mode --encrypt > "$scratch/reject.yaml" 2> /dev/null; then
    fail "--encrypt succeeds on $name"
  else
    pass
  fi
  grep -q '^sops:' "$scratch/reject.yaml" && fail "--encrypt emits ciphertext on $name" || pass
}

add_unknown_key() { echo "UNKNOWN_FIXTURE_KEY=$sentinel-unknown" >> "$fixtures/homelab.env"; }
drop_declared_key() { grep -v '^export TS_AUTHKEY=' "$fixtures/homelab.env" > "$fixtures/next" && mv "$fixtures/next" "$fixtures/homelab.env"; }
conflict_across_files() { echo "DATAFORSEO_API_KEY=$sentinel-other-dataforseo" >> "$fixtures/homelab.env"; }
empty_denied_value() { grep -v '^export TS_AUTHKEY=' "$fixtures/homelab.env" > "$fixtures/next" && echo "TS_AUTHKEY=" >> "$fixtures/next" && mv "$fixtures/next" "$fixtures/homelab.env"; }
single_quote_value() { grep -v '^SIGNOZ_JWT_SECRET=' "$fixtures/homelab.env" > "$fixtures/next" && echo "SIGNOZ_JWT_SECRET=\"$sentinel-it's\"" >> "$fixtures/next" && mv "$fixtures/next" "$fixtures/homelab.env"; }
empty_restic() { : > "$fixtures/restic.pass"; }

expect_rejection "an unknown key" UNKNOWN_FIXTURE_KEY add_unknown_key
expect_rejection "a missing declared key" TS_AUTHKEY drop_declared_key
expect_rejection "a key with different values in both files" DATAFORSEO_API_KEY conflict_across_files
expect_rejection "an empty value on a deny key" TS_AUTHKEY empty_denied_value
expect_rejection "a value holding a single quote" SIGNOZ_JWT_SECRET single_quote_value
expect_rejection "an empty restic password" restic empty_restic

write_good_fixtures
if run_script --preflight --env "$fixtures/homelab.env" --openseo-env "$fixtures/openseo.env" > "$scratch/flag.out" 2>&1; then
  fail "--preflight runs without --restic-pass"
else
  pass
fi
no_value_in "--preflight without --restic-pass" "$scratch/flag.out"

echo "$ran checks, $failures failed"
[ "$failures" -eq 0 ]
