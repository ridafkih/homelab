#!/bin/sh
set -eu

digest=sha256:a5d0ce49aa801d475da48f8cb163c354ab95cab073cd3c138bd458fc8257fbf1
apps="caddy authentik ridash jellyfin media seafile observability adguard open-webui"

for tool in docker-compose jq diff; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool"; exit 2; }
done

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)

scratch=$(mktemp -d -t compose-lint-tests.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

export DOCKER_HOST="unix://$scratch/no-docker-daemon.sock"

ran=0
failures=0

pass() { ran=$((ran + 1)); }
fail() { ran=$((ran + 1)); failures=$((failures + 1)); echo "FAIL: $1"; }
check() { if [ "$2" = "$3" ]; then pass; else fail "$1: expected [$3], got [$2]"; fi; }

work="$scratch/repo"
mkdir -p "$work"
for path in compose.yaml homelab.env apps scripts secrets tests; do
  cp -R "$repo/$path" "$work/$path"
done
chmod -R u+w "$work"

keys="$work/secrets/keys.tsv"

secret_names() {
  awk -F '\t' '{ if ($2 != "-") print $2; n = split($3, p, "/"); print p[n] }' "$1" | LC_ALL=C sort -u
}

reset_apps() {
  rm -rf "${work:?}/apps"
  if [ -e "$repo/apps" ]; then cp -R "$repo/apps" "$work/apps"; fi
}

lint_out=""
lint_rc=0
lint() {
  lint_rc=0
  lint_out=$(cd "$work" && sh scripts/compose-lint.sh "$@" 2>&1) || lint_rc=$?
}

rules_in_output() {
  printf '%s\n' "$lint_out" | sed -n 's/^[^:]*: [^:]*: \([a-f]\)[a-z-]*: .*$/\1/p' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

flagged_for() {
  printf '%s\n' "$lint_out" | grep -Eq "^[^:]*$2: $1: $3[a-z-]*: "
}

expect_lint() {
  name=$1 want_rc=$2 want_rules=$3
  shift 3
  lint "$@"
  check "lint $name exit" "$lint_rc" "$want_rc"
  check "lint $name rules" "$(rules_in_output)" "$want_rules"
  if [ "$lint_rc" != "$want_rc" ] || [ "$(rules_in_output)" != "$want_rules" ]; then
    printf '%s\n' "$lint_out" | sed 's/^/    | /'
  fi
}

expect_flagged() {
  file=$1 rule=$2
  shift 2
  for service in "$@"; do
    if flagged_for "$service" "$file" "$rule"; then pass; else fail "lint $file: service $service not flagged under rule $rule"; fi
  done
}

lint_root_and_apps() {
  set -- compose.yaml
  for app in $apps; do set -- "$@" "apps/$app/compose.yaml"; done
  lint --env-file homelab.env "$@"
}

fixtures=tests/fixtures/compose-lint

expect_lint compliant 0 "" --env-file homelab.env "$fixtures/compliant.yaml"
check "lint compliant prints nothing" "$lint_out" ""

expect_lint fallback 1 "a" --env-file homelab.env "$fixtures/fallback.yaml"
expect_flagged fallback.yaml a colon-dash dash colon-equals equals colon-plus plus bare unbraced

expect_lint floating-tag 1 "c" --env-file homelab.env "$fixtures/floating-tag.yaml"
expect_flagged floating-tag.yaml c latest tag-only no-tag no-image short-digest upper-digest interpolated built

expect_lint interpolated-secret 1 "b" --env-file homelab.env "$fixtures/interpolated-secret.yaml"
expect_flagged interpolated-secret.yaml b redis healthcheck caddy tunnel unlisted
for name in SEAFILE_REDIS_PASSWORD REDIS_PASSWORD CLOUDFLARE_API_TOKEN RIDASH_CLOUDFLARE_TUNNEL_TOKEN SOMETHING_NOT_IN_ANY_ENV_FILE; do
  if printf '%s\n' "$lint_out" | grep -q ": b[a-z-]*: .*$name"; then pass; else fail "lint interpolated-secret: rule b detail does not name $name"; fi
done

expect_lint "compliant without env file" 1 "b d" "$fixtures/compliant.yaml"
expect_flagged compliant.yaml b app

cases="$work/cases"
mkdir -p "$cases"

cat > "$cases/relative-escape.yaml" <<EOF
name: case-relative-escape

services:
  parent-escape:
    image: docker.io/library/busybox:1.37.0@$digest
    volumes:
      - ../../.data/caddy:/data
  dot-data:
    image: docker.io/library/busybox:1.37.0@$digest
    volumes:
      - ./.data/caddy:/data
  bare-data:
    image: docker.io/library/busybox:1.37.0@$digest
    volumes:
      - .data/caddy:/data
  hidden-authentik:
    image: docker.io/library/busybox:1.37.0@$digest
    volumes:
      - .authentik/media:/media
  inner-escape:
    image: docker.io/library/busybox:1.37.0@$digest
    volumes:
      - ./config/../../etc:/host-etc
  relative-value:
    image: docker.io/library/busybox:1.37.0@$digest
    volumes:
      - \${PROMETHEUS_RETENTION:?}/x:/x
  undeclared-volume:
    image: docker.io/library/busybox:1.37.0@$digest
    volumes:
      - not-declared:/x
  long-escape:
    image: docker.io/library/busybox:1.37.0@$digest
    volumes:
      - type: bind
        source: ../outside
        target: /outside
EOF
expect_lint relative-escape 1 "d" --env-file homelab.env "$cases/relative-escape.yaml"
expect_flagged relative-escape.yaml d parent-escape dot-data bare-data hidden-authentik inner-escape relative-value undeclared-volume long-escape

cat > "$cases/env-file.yaml" <<EOF
name: case-env-file

services:
  dotenv:
    image: docker.io/library/busybox:1.37.0@$digest
    env_file: .env
  unknown-template:
    image: docker.io/library/busybox:1.37.0@$digest
    env_file:
      - \${HOMELAB_SECRETS_DIR:?}/nope.env
  literal-dir:
    image: docker.io/library/busybox:1.37.0@$digest
    env_file:
      - /run/secrets/rendered/caddy.env
  wrong-dir:
    image: docker.io/library/busybox:1.37.0@$digest
    env_file:
      - \${HOMELAB_DATA_DIR:?}/caddy.env
  committed-file:
    image: docker.io/library/busybox:1.37.0@$digest
    env_file:
      - ./homelab.env
EOF
expect_lint env-file 1 "e" --env-file homelab.env "$cases/env-file.yaml"
expect_flagged env-file.yaml e dotenv unknown-template literal-dir wrong-dir committed-file

cat > "$cases/openseo-secret.yaml" <<EOF
name: case-openseo

services:
  init:
    image: docker.io/library/busybox:1.37.0@$digest
    environment:
      OPENROUTER_API_KEY: \${OPENROUTER_API_KEY?}
      AWS_ACCESS_KEY_ID: \${STORAGE_ACCESS_KEY:?}
EOF
expect_lint "openseo secret without --secret-env" 1 "b" --env-file homelab.env "$cases/openseo-secret.yaml"
expect_lint "openseo secret with --secret-env openseo.env" 0 "" --env-file homelab.env --secret-env openseo.env "$cases/openseo-secret.yaml"
expect_lint "openseo secret with another template" 1 "b" --env-file homelab.env --secret-env caddy.env "$cases/openseo-secret.yaml"

cat > "$cases/escaped.yaml" <<EOF
name: case-escaped

services:
  init:
    image: docker.io/library/busybox:1.37.0@$digest
    env_file:
      - \${HOMELAB_SECRETS_DIR:?}/adguard.env
    command:
      - sh
      - -c
      - ': "\$\${ADGUARD_USER:?missing}" "\$\${ADGUARD_PASSWORD_HASH}" "\$\$ADGUARD_USER"'
EOF
expect_lint escaped 0 "" --env-file homelab.env "$cases/escaped.yaml"

cat > "$cases/no-name.yaml" <<EOF
services:
  loose:
    image: docker.io/library/busybox:1.37.0@$digest
EOF
expect_lint "standalone file without name" 1 "f" --env-file homelab.env "$cases/no-name.yaml"

cat > "$cases/net-one.yaml" <<EOF
name: case-net-one

services:
  one:
    image: docker.io/library/busybox:1.37.0@$digest
    networks: [shared-net]

networks:
  shared-net:
    driver: bridge
EOF
sed -e 's/case-net-one/case-net-two/' -e 's/  one:/  two:/' "$cases/net-one.yaml" > "$cases/net-two.yaml"
expect_lint "network declared once" 0 "" --env-file homelab.env "$cases/net-one.yaml"
expect_lint "network declared twice across files" 1 "f" --env-file homelab.env "$cases/net-one.yaml" "$cases/net-two.yaml"

expect_lint "missing file" 2 "" --env-file homelab.env "$cases/does-not-exist.yaml"
expect_lint "no files" 2 "" --env-file homelab.env
printf 'services:\n  broken: [\n' > "$cases/broken.yaml"
expect_lint "unparseable file" 2 "" --env-file homelab.env "$cases/broken.yaml"

root_include=$(awk '/^include:/ { on = 1; next } /^[^ ]/ { on = 0 } on && /^  - / { sub(/^  - /, ""); print }' "$work/compose.yaml" | tr '\n' ' ' | sed 's/ $//')
want_include=""
for app in $apps; do want_include="$want_include apps/$app/compose.yaml"; done
check "root include list" "$root_include" "${want_include# }"

check "root sets name homelab" "$(grep -c '^name: homelab$' "$work/compose.yaml" || true)" "1"
check "root declares no services or volumes" "$(grep -cE '^(services|volumes):' "$work/compose.yaml" || true)" "0"
root_networks=$(awk '/^networks:/ { on = 1; next } /^[^ ]/ { on = 0 } on && /^  [^ #]/ { sub(/^ +/, ""); print }' "$work/compose.yaml" | tr '\n' ' ' | sed 's/ $//')
check "root declares only homelab-network" "$root_networks" "homelab-network:"

network_block() {
  awk '/^networks:/ { on = 1; next } /^[^ ]/ { on = 0 } on && /^  homelab-network:/ { grab = 1; print; next } grab && /^  [^ ]/ { grab = 0 } grab && on { print }' | sed -e '/^[[:space:]]*$/d'
}
want_block=$(printf '%s\n' \
  '  homelab-network:' \
  '    driver: bridge' \
  '    ipam:' \
  '      config:' \
  '        - subnet: 172.20.0.0/16' \
  '          gateway: 172.20.0.1')
new_block=$(network_block < "$work/compose.yaml")
check "homelab-network block keeps the live network's subnet and gateway" "$new_block" "$want_block"

for app in $apps; do
  if [ -f "$work/apps/$app/compose.yaml" ]; then pass; else fail "apps/$app/compose.yaml missing"; fi
done

data_dir="$scratch/data"
secrets_dir="$scratch/secrets"
mkdir -p "$data_dir" "$secrets_dir"
awk -F '\t' '$1 != "-" && $2 != "-" { print $2 "='"'"'dummy-" $3 "'"'"'" > (dir "/" $1) }' dir="$secrets_dir" "$work/secrets/keys.tsv"

render_rc=0
render=$(cd "$work" && HOMELAB_DATA_DIR="$data_dir" HOMELAB_SECRETS_DIR="$secrets_dir" docker-compose --env-file homelab.env config --format json 2>&1) || render_rc=$?
check "root renders with homelab.env" "$render_rc" "0"
if [ "$render_rc" = 0 ]; then
  check "root render name" "$(printf '%s' "$render" | jq -r .name)" "homelab"
fi

lint_root_and_apps
check "lint on root and the nine app files" "$lint_rc" "0"
[ "$lint_rc" = 0 ] || printf '%s\n' "$lint_out" | sed 's/^/    | /'

mkdir -p "$work/apps/caddy"
cat > "$work/apps/caddy/compose.yaml" <<EOF
services:
  probe:
    image: docker.io/library/busybox:1.37.0@$digest
    container_name: network-probe
    volumes:
      - \${HOMELAB_DATA_DIR:?}/probe:/probe
    networks:
      - homelab-network
EOF
probe_rc=0
probe=$(cd "$work" && HOMELAB_DATA_DIR="$data_dir" HOMELAB_SECRETS_DIR="$secrets_dir" docker-compose --env-file homelab.env config --format json 2>&1) || probe_rc=$?
check "probe render" "$probe_rc" "0"
if [ "$probe_rc" = 0 ]; then
  check "probe project name" "$(printf '%s' "$probe" | jq -r .name)" "homelab"
  check "homelab-network resolved name" "$(printf '%s' "$probe" | jq -r '.networks["homelab-network"].name')" "homelab_homelab-network"
  check "homelab-network driver" "$(printf '%s' "$probe" | jq -r '.networks["homelab-network"].driver')" "bridge"
  check "homelab-network ipam" "$(printf '%s' "$probe" | jq -c '.networks["homelab-network"].ipam.config')" '[{"subnet":"172.20.0.0/16","gateway":"172.20.0.1"}]'
  check "shell env overrides --env-file for HOMELAB_DATA_DIR" "$(printf '%s' "$probe" | jq -r '.services.probe.volumes[0].source')" "$data_dir/probe"
fi

lint_root_and_apps
check "lint accepts an app file that joins homelab-network" "$lint_rc" "0"

cat > "$work/apps/caddy/compose.yaml" <<EOF
services:
  probe:
    image: docker.io/library/busybox:1.37.0@$digest
    networks:
      - homelab-network

networks:
  homelab-network:
    driver: bridge
EOF
expect_lint "app file redeclaring homelab-network" 1 "f" --env-file homelab.env apps/caddy/compose.yaml

mkdir -p "$work/apps/adguard"
cat > "$work/apps/adguard/compose.yaml" <<EOF
name: adguard

services:
  probe:
    image: docker.io/library/busybox:1.37.0@$digest
EOF
expect_lint "included app file setting name" 1 "f" --env-file homelab.env apps/adguard/compose.yaml

reset_apps
rm -f "$work/apps/media/compose.yaml"
missing_rc=0
(cd "$work" && HOMELAB_DATA_DIR="$data_dir" HOMELAB_SECRETS_DIR="$secrets_dir" docker-compose --env-file homelab.env config --format json >/dev/null 2>&1) || missing_rc=$?
if [ "$missing_rc" != 0 ]; then pass; else fail "root render succeeds with a missing include"; fi
reset_apps

semantics="$scratch/semantics"
mkdir -p "$semantics"
cat > "$semantics/compose.yaml" <<EOF
name: semantics

services:
  probe:
    image: docker.io/library/busybox:1.37.0@$digest
    volumes:
      - \${HOMELAB_DATA_DIR:?}/probe:/probe
EOF
unset_rc=0
(cd "$semantics" && env -u HOMELAB_DATA_DIR docker-compose config --format json >/dev/null 2>&1) || unset_rc=$?
if [ "$unset_rc" != 0 ]; then pass; else fail "\${HOMELAB_DATA_DIR:?} renders while unset"; fi

if [ -f "$work/homelab.env" ]; then
  pass
  env_file="$work/homelab.env"
  value_of() { sed -n "s/^$1=//p" "$env_file"; }
  check "homelab.env CADDY_DOMAIN" "$(value_of CADDY_DOMAIN)" "rida.sh"
  check "homelab.env CADDY_HOST_MACHINE_HOSTNAME" "$(value_of CADDY_HOST_MACHINE_HOSTNAME)" "172.17.0.1"
  check "homelab.env PROMETHEUS_RETENTION" "$(value_of PROMETHEUS_RETENTION)" "30d"
  check "homelab.env SEAFILE_DATA_PATH" "$(value_of SEAFILE_DATA_PATH)" "/data/seafile"
  check "homelab.env HOMELAB_DATA_DIR" "$(value_of HOMELAB_DATA_DIR)" "/home/rida/homelab/.data"
  check "homelab.env HOMELAB_SECRETS_DIR" "$(value_of HOMELAB_SECRETS_DIR)" "/run/secrets/rendered"
  for key in AUTHENTIK_POSTGRESQL__HOST AUTHENTIK_POSTGRESQL__NAME AUTHENTIK_REDIS__HOST; do
    if value_of "$key" | grep -Eqx '[A-Za-z0-9._-]+'; then pass; else fail "homelab.env $key must be a plain host or database name"; fi
  done
  check "homelab.env has no HOMELAB_DIR" "$(grep -c '^HOMELAB_DIR=' "$env_file" || true)" "0"
  check "homelab.env lines are all KEY=value" "$(grep -cvE '^[A-Z][A-Z0-9_]*=[^ $]+$' "$env_file" || true)" "0"
  check "homelab.env has no duplicate keys" "$(cut -d= -f1 "$env_file" | sort | uniq -d | tr '\n' ' ')" ""
  allowed="AUTHENTIK_POSTGRESQL__HOST AUTHENTIK_POSTGRESQL__NAME AUTHENTIK_REDIS__HOST CADDY_DOMAIN CADDY_HOST_MACHINE_HOSTNAME HOMELAB_DATA_DIR HOMELAB_SECRETS_DIR PROMETHEUS_RETENTION SEAFILE_DATA_PATH"
  while IFS='=' read -r key _; do
    case " $allowed " in
      *" $key "*) pass ;;
      *) case "$key" in AUTHENTIK_*) pass ;; *) fail "homelab.env has unlisted key $key" ;; esac ;;
    esac
  done < "$env_file"
  for table in "$keys" "$repo/secrets/keys.tsv"; do
    [ -f "$table" ] || continue
    secret_names "$table" > "$scratch/secret-names"
    leaked=$(cut -d= -f1 "$env_file" | LC_ALL=C sort -u | comm -12 - "$scratch/secret-names" | tr '\n' ' ' | sed 's/ $//')
    check "homelab.env shares no key with $table" "$leaked" ""
  done
else
  fail "homelab.env missing"
fi

if [ "$ran" = 0 ]; then
  echo "no test cases ran"
  exit 1
fi
echo "$ran checks, $failures failed"
[ "$failures" = 0 ]
