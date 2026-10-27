#!/bin/sh
set -eu

baseline=9af811a
adguard_image='adguard/adguardhome'
adguard_digest='sha256:aba9e3bf0613be3ba3755e1fc311b126e2c24bec25e18b6483894a88283074f0'
alpine_image='alpine'
alpine_digest='sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a'
webui_image='ghcr.io/open-webui/open-webui'
webui_digest='sha256:096c8f3d3132016210ca87b0b4dff01d2d66d9fe4fee088fae13fc30f9ac54f3'
dummy_user='admin'
dummy_hash='$2y$10$dummy.adguard.hash/with$dollars.and.slashes0123456789ab'

for tool in docker-compose jq git diff gitleaks; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool"; exit 2; }
done

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$repo"
git cat-file -e "$baseline^{commit}" 2>/dev/null || { echo "baseline $baseline is not in $repo"; exit 2; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/compose-dns-ai.XXXXXX")
trap 'rm -rf "$scratch"' EXIT INT TERM
export DOCKER_HOST="unix://$scratch/no-docker-daemon.sock"

ran=0
failures=0
pass() { ran=$((ran + 1)); }
fail() { ran=$((ran + 1)); failures=$((failures + 1)); echo "FAIL: $1"; }
check() { if [ "$2" = "$3" ]; then pass; else fail "$1: expected [$3], got [$2]"; fi; }
holds() { if eval "$2"; then pass; else fail "$1"; fi; }

adguard=apps/adguard/compose.yaml
webui=apps/open-webui/compose.yaml
template=apps/adguard/AdGuardHome.yaml

secrets="$scratch/secrets"
data="$scratch/data"
mkdir -p "$secrets" "$data"
awk -F '\t' '$1 != "-" && $2 != "-" { print $2 "='"'"'dummy-" $3 "'"'"'" > (dir "/" $1) }' dir="$secrets" secrets/keys.tsv
printf "ADGUARD_USER='%s'\nADGUARD_PASSWORD_HASH='%s'\n" "$dummy_user" "$dummy_hash" > "$secrets/adguard.env"

raw() {
  docker-compose -f "$1" config --no-interpolate --no-consistency --no-path-resolution --format json 2>/dev/null || echo '{}'
}

rendered="$scratch/root.json"
env -i PATH="$PATH" HOME="$HOME" DOCKER_HOST="$DOCKER_HOST" \
  HOMELAB_DATA_DIR="$data" HOMELAB_SECRETS_DIR="$secrets" \
  docker-compose -f compose.yaml --env-file homelab.env config --format json > "$rendered" 2> "$scratch/render.err" || {
  fail "root compose.yaml does not render: $(cat "$scratch/render.err")"
  echo '{}' > "$rendered"
}
svc() { jq -c --arg s "$1" ".services[\$s] // {} | $2" "$rendered"; }
unescaped() { svc "$1" "$2" | jq -r '. // "" | gsub("\\$\\$"; "$")'; }

raw "$adguard" > "$scratch/adguard.raw.json"
raw "$webui" > "$scratch/webui.raw.json"

check "apps/adguard services" "$(jq -c '.services // {} | keys' "$scratch/adguard.raw.json")" '["adguard","adguard-init"]'
check "apps/open-webui services" "$(jq -c '.services // {} | keys' "$scratch/webui.raw.json")" '["open-webui"]'

check "adguard-init image" "$(jq -r '.services["adguard-init"].image // ""' "$scratch/adguard.raw.json" | sed -E 's/:[^:@]+@/@/')" "$alpine_image@$alpine_digest"
check "adguard image" "$(jq -r '.services.adguard.image // ""' "$scratch/adguard.raw.json" | sed -E 's/:[^:@]+@/@/')" "$adguard_image@$adguard_digest"
check "open-webui image" "$(jq -r '.services["open-webui"].image // ""' "$scratch/webui.raw.json" | sed -E 's/:[^:@]+@/@/')" "$webui_image@$webui_digest"
for render in "$scratch/adguard.raw.json" "$scratch/webui.raw.json"; do
  for image in $(jq -r '.services // {} | .[] | .image // "none"' "$render"); do
    holds "$image is a literal repo:tag@sha256 pin" "printf '%s' '$image' | grep -Eq '^[^\$@]+:[^@\$:/]+@sha256:[0-9a-f]{64}\$'"
  done
done

check "adguard-init container_name" "$(svc adguard-init '.container_name')" '"adguardhome-init"'
check "adguard container_name" "$(svc adguard '.container_name')" '"adguardhome"'
check "open-webui container_name" "$(svc open-webui '.container_name')" '"open-webui"'
check "adguard network_mode" "$(svc adguard '.network_mode')" '"host"'
check "adguard restart" "$(svc adguard '.restart')" '"unless-stopped"'
check "open-webui restart" "$(svc open-webui '.restart')" '"always"'
check "adguard depends_on" "$(svc adguard '.depends_on["adguard-init"].condition')" '"service_completed_successfully"'
check "open-webui networks" "$(svc open-webui '.networks // {} | keys')" '["homelab-network"]'
check "adguard volumes" "$(svc adguard '[.volumes[]? | "\(.source):\(.target):\(.read_only // false)"]')" \
  "[\"$data/adguardhome/work:/opt/adguardhome/work:false\",\"$data/adguardhome/conf:/opt/adguardhome/conf:false\",\"/etc/homelab-ca/certs:/etc/ssl/certs:true\"]"
check "adguard-init volumes" "$(svc adguard-init '[.volumes[]? | "\(.source):\(.target):\(.read_only // false)"]')" \
  "[\"$repo/$template:/src/AdGuardHome.yaml:true\",\"$data/adguardhome/conf:/dst:false\"]"
check "open-webui volumes" "$(svc open-webui '[.volumes[]? | "\(.source):\(.target)"]')" \
  "[\"$data/open-webui/app/backend/data:/app/backend/data\"]"

check "adguard-init env_file" "$(jq -c '.services["adguard-init"].env_file // [] | [.[] | if type == "object" then .path else . end]' "$scratch/adguard.raw.json")" '["${HOMELAB_SECRETS_DIR:?}/adguard.env"]'
holds "adguard-init has no environment: entries (0004)" "! grep -Eq '^ *environment:' '$adguard'"
holds "no env_file uses format: raw (0004)" "! grep -Eq 'format: *raw' '$adguard' '$webui'"
check "adguard-init rendered ADGUARD_USER" "$(unescaped adguard-init '.environment.ADGUARD_USER')" "$dummy_user"
check "adguard-init rendered ADGUARD_PASSWORD_HASH byte for byte" "$(unescaped adguard-init '.environment.ADGUARD_PASSWORD_HASH')" "$dummy_hash"
check "open-webui has no environment" "$(jq -c '.services["open-webui"].environment // null' "$scratch/webui.raw.json")" 'null'

init_script="$scratch/init.sh"
unescaped adguard-init '.command[2]' | sed -e "s|/src/|$scratch/src/|g" -e "s|/dst/|$scratch/dst/|g" > "$init_script"
mkdir -p "$scratch/src" "$scratch/dst"
cp "$template" "$scratch/src/AdGuardHome.yaml" 2>/dev/null || true
if env ADGUARD_USER="$dummy_user" ADGUARD_PASSWORD_HASH="$dummy_hash" sh -eu "$init_script" > /dev/null 2>&1; then
  check "init renders the user" "$(grep -F "name: $dummy_user" "$scratch/dst/AdGuardHome.yaml" 2>/dev/null | sed 's/^ *//')" "- name: $dummy_user"
  check "init renders the hash byte for byte" "$(grep -F "password: " "$scratch/dst/AdGuardHome.yaml" 2>/dev/null | sed 's/^ *//')" "password: $dummy_hash"
else
  fail "adguard-init command does not render the template"
fi
holds "init fails without the secrets" "! env -u ADGUARD_USER -u ADGUARD_PASSWORD_HASH sh -eu '$init_script' > /dev/null 2>&1"

holds "config/adguardhome/AdGuardHome.yaml is moved away" "[ ! -e config/adguardhome/AdGuardHome.yaml ] && [ -z \"\$(git ls-files config/adguardhome)\" ]"
holds "$template is byte-identical to $baseline:config/adguardhome/AdGuardHome.yaml" \
  "git show '$baseline:config/adguardhome/AdGuardHome.yaml' | cmp -s - '$template'"
holds "$template history follows the git mv" \
  "git log --follow --name-only --format= -- '$template' 2>/dev/null | grep -qx config/adguardhome/AdGuardHome.yaml"
holds "$template keeps __ADGUARD_USER__" "grep -q 'name: __ADGUARD_USER__\$' '$template' 2>/dev/null"
holds "$template keeps __ADGUARD_PASSWORD_HASH__" "grep -q 'password: __ADGUARD_PASSWORD_HASH__\$' '$template' 2>/dev/null"
holds "$template has no bcrypt hash" "[ -f '$template' ] && ! grep -Eq '\\\$2[aby]\\\$' '$template'"
holds "$template binds 0.0.0.0" "grep -A1 'bind_hosts:' '$template' 2>/dev/null | grep -q -- '- 0.0.0.0'"

holds "no OLLAMA reference in apps/open-webui" "[ -f '$webui' ] && ! grep -rqi ollama apps/open-webui"

for dir in apps/adguard apps/open-webui; do
  holds "gitleaks finds nothing in $dir" "gitleaks dir --no-banner --redact '$dir' > '$scratch/gitleaks.out' 2>&1"
done

lint_out="$scratch/lint.out"
if sh scripts/compose-lint.sh --env-file homelab.env "$adguard" "$webui" > "$lint_out" 2>&1; then
  pass
else
  fail "compose-lint.sh: $(cat "$lint_out")"
fi

allowed_change='^[+-] *("image": |"source": .*(config/adguardhome|apps/adguard/AdGuardHome\.yaml)|"target": "/src)'
for pair in "$adguard:adguard adguard-init" "$webui:open-webui"; do
  file=${pair%%:*}
  diff_out="$scratch/diff.out"
  status=0
  sh scripts/compose-diff.sh homelab compose.yaml "$file" > "$diff_out" 2>&1 || status=$?
  holds "compose-diff.sh on $file exits 0 or 1 (got $status): $(head -5 "$diff_out")" "[ $status -le 1 ]"
  unexpected=$(sed '/^Services in /,$d' "$diff_out" | grep -E '^[+-]' | grep -vE '^(\+\+\+|---) ' | grep -vE "$allowed_change" || true)
  check "compose-diff.sh on $file shows only pins and path moves" "$unexpected" ""
  for name in ${pair#*:}; do
    holds "compose-diff.sh on $file keeps $name" "! sed -n '/^Services in /,\$p' '$diff_out' | grep -qx '  - $name'"
  done
done

echo "$ran checks, $failures failed"
[ "$failures" -eq 0 ]
