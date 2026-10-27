#!/bin/sh
set -eu

baseline=9af811a
app=apps/seafile/compose.yaml
template=seafile.env
live_dir=/home/rida/homelab
services="seafile-db seafile-redis seafile seadoc"
allowed_vars="CADDY_DOMAIN HOMELAB_DATA_DIR HOMELAB_SECRETS_DIR SEAFILE_DATA_PATH"

for tool in docker-compose jq git diff; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool"; exit 2; }
done

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
git -C "$repo" cat-file -e "$baseline^{commit}" 2>/dev/null || { echo "baseline $baseline is not in $repo"; exit 2; }
keys="$repo/secrets/keys.tsv"
[ -f "$keys" ] || { echo "missing $keys"; exit 2; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/seafile-tests.XXXXXX")
trap 'rm -rf "$scratch"' EXIT INT TERM
scratch=$(CDPATH='' cd -- "$scratch" && pwd -P)

docker_host="unix://$scratch/no-docker-daemon.sock"

ran=0
failures=0
pass() { ran=$((ran + 1)); }
fail() { ran=$((ran + 1)); failures=$((failures + 1)); echo "FAIL: $1"; }
check() { if [ "$2" = "$3" ]; then pass; else fail "$1: expected [$3], got [$2]"; fi; }

finish() {
  echo "$ran checks, $failures failed"
  [ "$failures" -eq 0 ]
  exit $?
}

expected_image() {
  case $1 in
    seafile-db) echo "mariadb:10.11@sha256:d769e37960821dfdcf096954f6e7ac89f747e116c1bba98e48edd265dfc7deae" ;;
    seafile-redis) echo "redis:7-alpine@sha256:6ba19c50b56777f5c11c58eff8ddb69d0d5f27ba131cffb63f180ccfd43c66af" ;;
    seafile) echo "seafileltd/seafile-mc:13.0-latest@sha256:b0c90832126bf432db908449f1bb450211e6bbf75a2193bab3399e2a9636eccf" ;;
    seadoc) echo "seafileltd/sdoc-server:2.0-latest@sha256:c97025a731ee08d67668edd02ee9d08bb5ebc92fa762d96d2cda91de4c11ad04" ;;
  esac
}

if [ ! -f "$repo/$app" ]; then
  fail "$app does not exist"
  finish
fi

template_keys=$(awk -F '\t' -v t="$template" '$1 == t && $2 != "-" { print $2 }' "$keys" | LC_ALL=C sort -u | jq -R . | jq -s -c .)
check "keys.tsv lists $template keys" "$(printf '%s' "$template_keys" | jq 'length > 0')" "true"

secrets_dir="$scratch/secrets"
mkdir -p "$secrets_dir"
awk -F '\t' '$1 != "-" && $2 != "-" { print $2 "='"'"'dummy-" $3 "'"'"'" > (dir "/" $1) }' dir="$secrets_dir" "$keys"

homelab_env="$repo/homelab.env"
env_value() { sed -n "s/^$1=//p" "$homelab_env"; }
check "homelab.env SEAFILE_DATA_PATH" "$(env_value SEAFILE_DATA_PATH)" "/data/seafile"
check "homelab.env HOMELAB_DATA_DIR" "$(env_value HOMELAB_DATA_DIR)" "$live_dir/.data"
check "homelab.env CADDY_DOMAIN" "$(env_value CADDY_DOMAIN)" "rida.sh"

wrapper="$scratch/new/compose.yaml"
mkdir -p "$scratch/new/apps"
ln -s "$repo/apps/seafile" "$scratch/new/apps/seafile"
{
  echo "name: homelab"
  echo
  echo "include:"
  echo "  - $app"
  echo
  awk '/^networks:/ { on = 1 } /^[^ ]/ && !/^networks:/ { on = 0 } on' "$repo/compose.yaml"
} > "$wrapper"

if grep -Eq "^  - $app\$" "$repo/compose.yaml"; then pass; else fail "root compose.yaml does not include $app"; fi

render() {
  env_file=$1
  shift
  env -i PATH="$PATH" HOME="$HOME" DOCKER_HOST="$docker_host" "$@" \
    docker-compose -p homelab --env-file "$env_file" -f "$wrapper" config --format json
}

new_json="$scratch/new.json"
if render "$homelab_env" HOMELAB_SECRETS_DIR="$secrets_dir" > "$new_json" 2> "$scratch/new.err"; then
  pass
else
  fail "rendering $app through name: homelab include failed: $(cat "$scratch/new.err")"
  finish
fi

old_dir="$scratch/old"
mkdir -p "$old_dir"
git -C "$repo" show "$baseline:compose.yaml" > "$old_dir/compose.yaml"
old_env="$scratch/old.env"
{
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$homelab_env"
  awk -F '\t' -v t="$template" '$1 == t { n = split($3, p, "/"); print p[n] "=dummy-" $3 }' "$keys"
} | awk -F '=' '!seen[$1]++' > "$old_env"
cp "$old_env" "$old_dir/.env"
old_json="$scratch/old.json"
if env -i PATH="$PATH" HOME="$HOME" DOCKER_HOST="$docker_host" \
  docker-compose -p homelab --env-file "$old_env" -f "$old_dir/compose.yaml" config --format json > "$old_json" 2> "$scratch/old.err"; then
  pass
else
  fail "rendering $baseline:compose.yaml failed: $(cat "$scratch/old.err")"
  finish
fi

relocate='
  walk(
    if type == "string" then
      (if startswith($a + "/") then $live + .[($a | length):] elif startswith($b + "/") then $live + .[($b | length):] else . end)
    else . end)
'
jq --arg a "$old_dir" --arg b "$(printf "%s" "$old_dir" | sed "s|^/private/|/|")" --arg live "$live_dir" "$relocate" "$old_json" > "$scratch/old.live.json"

for service in $services; do
  check "$service container_name" "$(jq -r --arg s "$service" '.services[$s].container_name // "missing"' "$new_json")" "$service"
  check "$service image pinned to the running digest" "$(jq -r --arg s "$service" '.services[$s].image // "missing"' "$new_json")" "$(expected_image "$service")"
done

check "seafile-database volume name" "$(jq -r '.volumes["seafile-database"].name // "missing"' "$new_json")" "homelab_seafile-database"
check "seafile-network name" "$(jq -r '.networks["seafile-network"].name // "missing"' "$new_json")" "homelab_seafile-network"
check "homelab-network name" "$(jq -r '.networks["homelab-network"].name // "missing"' "$new_json")" "homelab_homelab-network"
for key in seafile-network homelab-network; do
  check "network $key matches $baseline" "$(jq -S -c --arg k "$key" '.networks[$k]' "$new_json")" "$(jq -S -c --arg k "$key" '.networks[$k]' "$scratch/old.live.json")"
done
check "volume seafile-database matches $baseline" "$(jq -S -c '.volumes["seafile-database"]' "$new_json")" "$(jq -S -c '.volumes["seafile-database"]' "$scratch/old.live.json")"

bind_source() {
  jq -r --arg s "$1" '[.services[$s].volumes // [] | .[] | select(.target == "/shared") | .source] | first // "missing"' "$new_json"
}
check "seafile /shared bind source" "$(bind_source seafile)" "/data/seafile"
check "seadoc /shared bind source" "$(bind_source seadoc)" "$live_dir/.data/seadoc"

compare='
  def strip($s):
    del(.image, .environment)
    | if $s == "seafile-redis" then del(.command) | del(.healthcheck.test) else . end;
  $old[0].services[$s] as $o
  | .services[$s] as $n
  | ($o.environment // {}) as $oe
  | ($n.environment // {}) as $ne
  | [
      ($oe | to_entries[] | select($ne[.key] != .value) | "environment \(.key) changed"),
      ($ne | keys[] | select(. as $k | $oe | has($k) | not) | select(. as $k | $allowed | index($k) | not) | "environment \(.) added and is not a \($template) key"),
      (if ($o | strip($s)) != ($n | strip($s)) then "non-allowlisted change: \(($o | strip($s)) | tojson) -> \(($n | strip($s)) | tojson)" else empty end)
    ]
  | if length == 0 then "ok" else join("; ") end
'
for service in $services; do
  check "$service differs from $baseline only by pin, env_file and fail-fast" \
    "$(jq -r --arg s "$service" --arg template "$template" --argjson allowed "$template_keys" --slurpfile old "$scratch/old.live.json" "$compare" "$new_json")" "ok"
done

expect_env() {
  service=$1 key=$2 secret=$3
  check "$service gets $key from $template" "$(jq -r --arg s "$service" --arg k "$key" '.services[$s].environment[$k] // "missing"' "$new_json")" "dummy-$secret"
}
expect_env seafile-db MYSQL_ROOT_PASSWORD seafile/SEAFILE_MYSQL_ROOT_PASSWORD
expect_env seafile-redis REDIS_PASSWORD seafile/SEAFILE_REDIS_PASSWORD
expect_env seafile SEAFILE_MYSQL_DB_PASSWORD seafile/SEAFILE_MYSQL_PASSWORD
expect_env seafile INIT_SEAFILE_MYSQL_ROOT_PASSWORD seafile/SEAFILE_MYSQL_ROOT_PASSWORD
expect_env seafile INIT_SEAFILE_ADMIN_EMAIL seafile/SEAFILE_ADMIN_EMAIL
expect_env seafile INIT_SEAFILE_ADMIN_PASSWORD seafile/SEAFILE_ADMIN_PASSWORD
expect_env seafile JWT_PRIVATE_KEY seafile/SEAFILE_JWT_PRIVATE_KEY
expect_env seafile REDIS_PASSWORD seafile/SEAFILE_REDIS_PASSWORD
expect_env seadoc DB_PASSWORD seafile/SEAFILE_MYSQL_PASSWORD
expect_env seadoc JWT_PRIVATE_KEY seafile/SEAFILE_JWT_PRIVATE_KEY

leaks=$(jq -r --argjson names "$(printf '%s\n' $services | jq -R . | jq -s -c .)" '
  [.services | to_entries[] | select(.key as $k | $names | index($k)) | .value | del(.environment)]
  | [.. | strings | select(contains("dummy-"))] | unique | join(", ")
' "$new_json")
check "no secret value rendered outside environment" "$leaks" ""

redis_command=$(jq -r '.services["seafile-redis"].command // [] | join(" ")' "$new_json")
redis_health=$(jq -r '.services["seafile-redis"].healthcheck.test // [] | join(" ")' "$new_json")
if printf '%s' "$redis_command" | grep -Eq -- '--requirepass[^-]*\$\$\{?REDIS_PASSWORD'; then pass; else fail "seafile-redis command does not pass \$\$REDIS_PASSWORD to --requirepass: [$redis_command]"; fi
for flag in "redis-server" "--save ''" "--appendonly no"; do
  case $redis_command in *"$flag"*) pass ;; *) fail "seafile-redis command lost [$flag]: [$redis_command]" ;; esac
done
if printf '%s' "$redis_health" | grep -Eq '\$\$\{?REDIS_PASSWORD' && printf '%s' "$redis_health" | grep -q 'redis-cli' && printf '%s' "$redis_health" | grep -q 'ping'; then
  pass
else
  fail "seafile-redis healthcheck does not ping with \$\$REDIS_PASSWORD: [$redis_health]"
fi

raw_json="$scratch/raw.json"
env -i PATH="$PATH" HOME="$HOME" DOCKER_HOST="$docker_host" \
  docker-compose -f "$repo/$app" config --no-interpolate --no-consistency --no-path-resolution --format json > "$raw_json" 2> "$scratch/raw.err" || {
  fail "$app does not parse: $(cat "$scratch/raw.err")"
  finish
}
if grep -Eq '^name:' "$repo/$app"; then fail "$app sets a top-level name"; else pass; fi
check "$app declares seafile-network" "$(jq -r '.networks // {} | has("seafile-network")' "$raw_json")" "true"
check "$app does not declare homelab-network" "$(jq -r '.networks // {} | has("homelab-network")' "$raw_json")" "false"
check "$app declares seafile-database" "$(jq -r '.volumes // {} | has("seafile-database")' "$raw_json")" "true"
for service in $services; do
  check "$service env_file" "$(jq -c --arg s "$service" '[.services[$s].env_file // [] | .[] | if type == "object" then .path else . end]' "$raw_json")" "[\"\${HOMELAB_SECRETS_DIR:?}/$template\"]"
  check "$service has no secret environment keys" \
    "$(jq -r --arg s "$service" --argjson allowed "$template_keys" '[.services[$s].environment // {} | keys[] | select(. as $k | $allowed | index($k))] | join(",")' "$raw_json")" ""
done

interpolated=$(sed 's/\$\$//g' "$repo/$app" | grep -oE '\$\{[^}]*\}?|\$[A-Za-z_][A-Za-z0-9_]*' | LC_ALL=C sort -u || true)
unexpected_refs() {
  printf '%s\n' "$interpolated" | grep -v '^$' | while read -r ref; do
    name=$(printf '%s' "$ref" | sed -E 's/^\$\{?([A-Za-z_][A-Za-z0-9_]*).*$/\1/')
    case " $allowed_vars " in
      *" $name "*) [ "$ref" = "$(printf '${%s:?}' "$name")" ] || echo "$ref" ;;
      *) echo "$ref" ;;
    esac
  done | tr '\n' ' ' | sed 's/ $//'
}
bad=$(unexpected_refs)
check "$app interpolates only fail-fast non-secret variables" "$bad" ""
if grep -q ':-' "$repo/$app"; then fail "$app still has a :- fallback"; else pass; fi
for var in $allowed_vars; do
  if printf '%s\n' "$interpolated" | grep -qxF "$(printf '${%s:?}' "$var")"; then pass; else fail "$app does not use \${$var:?}"; fi
done

for var in $allowed_vars; do
  stripped="$scratch/without-$var.env"
  grep -v "^$var=" "$homelab_env" > "$stripped"
  if [ "$var" = HOMELAB_SECRETS_DIR ]; then
    rc=0
    render "$stripped" > /dev/null 2> "$scratch/neg.err" || rc=$?
  else
    rc=0
    render "$stripped" HOMELAB_SECRETS_DIR="$secrets_dir" > /dev/null 2> "$scratch/neg.err" || rc=$?
  fi
  if [ "$rc" -ne 0 ] && grep -q "$var" "$scratch/neg.err"; then pass; else fail "render without $var did not fail on it (exit $rc): $(cat "$scratch/neg.err")"; fi
done

lint_rc=0
lint_out=$(cd "$repo" && sh scripts/compose-lint.sh --env-file homelab.env "$app" 2>&1) || lint_rc=$?
check "compose-lint exit" "$lint_rc" "0"
[ "$lint_rc" -eq 0 ] || printf '%s\n' "$lint_out" | sed 's/^/    | /'

diff_rc=0
diff_out=$(cd "$repo" && env DOCKER_HOST="$docker_host" sh scripts/compose-diff.sh homelab compose.yaml "$app" 2>&1) || diff_rc=$?
if [ "$diff_rc" -le 1 ]; then pass; else fail "compose-diff exit $diff_rc: $diff_out"; fi
dropped=$(printf '%s\n' "$diff_out" | sed -n '/does not define:$/,$p' | sed -n 's/^  - //p')
for service in $services; do
  if printf '%s\n' "$dropped" | grep -qx "$service"; then fail "compose-diff reports $service missing from $app"; else pass; fi
done
for field in container_name '"name"' networks depends_on; do
  changed=$(printf '%s\n' "$diff_out" | grep -E '^[-+] ' | grep -F "$field" || true)
  check "compose-diff shows no $field change" "$changed" ""
done

finish
