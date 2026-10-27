#!/bin/sh
set -eu

baseline=9af811a
digest=sha256:a5d0ce49aa801d475da48f8cb163c354ab95cab073cd3c138bd458fc8257fbf1
apps="caddy authentik ridash jellyfin media seafile observability adguard open-webui"

for tool in docker-compose jq git diff; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool"; exit 2; }
done

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
git -C "$repo" cat-file -e "$baseline^{commit}" 2>/dev/null || { echo "baseline $baseline is not in $repo"; exit 2; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/compose-tests.XXXXXX")
trap 'rm -rf "$scratch"' EXIT INT TERM

export DOCKER_HOST="unix://$scratch/no-docker-daemon.sock"

ran=0
failures=0

pass() { ran=$((ran + 1)); }
fail() { ran=$((ran + 1)); failures=$((failures + 1)); echo "FAIL: $1"; }
check() { if [ "$2" = "$3" ]; then pass; else fail "$1: expected [$3], got [$2]"; fi; }

work="$scratch/repo"
git clone -q --shared --no-checkout "$repo" "$work"
git -C "$work" checkout -q --detach "$(git -C "$repo" rev-parse HEAD)"
for path in compose.yaml homelab.env apps scripts secrets; do
  rm -rf "${work:?}/$path"
  if [ -e "$repo/$path" ]; then cp -R "$repo/$path" "$work/$path"; fi
done

if [ ! -f "$work/secrets/keys.tsv" ]; then
  mkdir -p "$work/secrets"
  while read -r template env_key secret empty; do
    printf '%s\t%s\t%s\t%s\n' "$template" "$env_key" "$secret" "$empty"
  done > "$work/secrets/keys.tsv" <<'EOF'
adguard.env ADGUARD_PASSWORD_HASH adguard/ADGUARD_PASSWORD_HASH deny
adguard.env ADGUARD_USER adguard/ADGUARD_USER deny
authentik-tunnel.env TUNNEL_TOKEN authentik/AUTHENTIK_CLOUDFLARE_TUNNEL_TOKEN deny
authentik.env AUTHENTIK_POSTGRESQL__PASSWORD authentik/AUTHENTIK_POSTGRESQL__PASSWORD deny
authentik.env AUTHENTIK_POSTGRESQL__USER authentik/AUTHENTIK_POSTGRESQL__USER deny
authentik.env AUTHENTIK_SECRET_KEY authentik/AUTHENTIK_SECRET_KEY deny
authentik.env POSTGRES_PASSWORD authentik/AUTHENTIK_POSTGRESQL__PASSWORD deny
authentik.env POSTGRES_USER authentik/AUTHENTIK_POSTGRESQL__USER deny
caddy.env CLOUDFLARE_API_TOKEN caddy/CADDY_CLOUDFLARE_API_TOKEN deny
grafana.env GF_SECURITY_ADMIN_PASSWORD grafana/GRAFANA_ADMIN_PASSWORD deny
grafana.env GF_SECURITY_ADMIN_USER grafana/GRAFANA_ADMIN_USER deny
openseo.env CONTEXT_API_KEY openseo/CONTEXT_API_KEY allow
openseo.env DATAFORSEO_API_KEY openseo/DATAFORSEO_API_KEY deny
openseo.env GOOGLE_CLIENT_ID openseo/GOOGLE_CLIENT_ID deny
openseo.env GOOGLE_CLIENT_SECRET openseo/GOOGLE_CLIENT_SECRET deny
openseo.env OPENROUTER_API_KEY openseo/OPENROUTER_API_KEY allow
openseo.env STORAGE_ACCESS_KEY openseo/STORAGE_ACCESS_KEY deny
openseo.env STORAGE_SECRET_KEY openseo/STORAGE_SECRET_KEY deny
otel.env OTEL_AUTH_TOKEN otel/OTEL_AUTH_TOKEN deny
ridash.env TUNNEL_TOKEN ridash/RIDASH_CLOUDFLARE_TUNNEL_TOKEN deny
seafile.env DB_PASSWORD seafile/SEAFILE_MYSQL_PASSWORD deny
seafile.env INIT_SEAFILE_ADMIN_EMAIL seafile/SEAFILE_ADMIN_EMAIL deny
seafile.env INIT_SEAFILE_ADMIN_PASSWORD seafile/SEAFILE_ADMIN_PASSWORD deny
seafile.env INIT_SEAFILE_MYSQL_ROOT_PASSWORD seafile/SEAFILE_MYSQL_ROOT_PASSWORD deny
seafile.env JWT_PRIVATE_KEY seafile/SEAFILE_JWT_PRIVATE_KEY deny
seafile.env MYSQL_ROOT_PASSWORD seafile/SEAFILE_MYSQL_ROOT_PASSWORD deny
seafile.env REDIS_PASSWORD seafile/SEAFILE_REDIS_PASSWORD deny
seafile.env SEAFILE_MYSQL_DB_PASSWORD seafile/SEAFILE_MYSQL_PASSWORD deny
signoz.env SIGNOZ_TOKENIZER_JWT_SECRET signoz/SIGNOZ_JWT_SECRET deny
tailscale-funnel.env TS_AUTHKEY tailscale-funnel/TS_AUTHKEY deny
- - restic/RESTIC_PASSWORD deny
EOF
fi
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

fixtures=scripts/tests/fixtures

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
old_block=$(git -C "$repo" show "$baseline:compose.yaml" | network_block)
new_block=$(network_block < "$work/compose.yaml")
check "homelab-network block copied byte for byte from $baseline" "$new_block" "$old_block"

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

diff_out=""
diff_rc=0
run_diff() {
  diff_rc=0
  diff_out=$(cd "$work" && sh scripts/compose-diff.sh "$@" 2>&1) || diff_rc=$?
}

changed_lines() {
  printf '%s\n' "$diff_out" | grep -E '^[-+]' | grep -vE '^(---|\+\+\+) '
}

trailer_lists() {
  printf '%s\n' "$diff_out" | grep -Eq "^[[:space:]-]*$1\$"
}

show_diff() {
  printf '%s\n' "$diff_out" | sed 's/^/    | /'
}

mkdir -p "$work/apps/open-webui"
cat > "$work/apps/open-webui/compose.yaml" <<'EOF'
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    volumes:
      - ${HOMELAB_DATA_DIR:?}/open-webui/app/backend/data:/app/backend/data
    restart: always
    networks:
      - homelab-network
EOF
run_diff homelab compose.yaml apps/open-webui/compose.yaml
check "diff pure move from .data to HOMELAB_DATA_DIR exit" "$diff_rc" "0"
check "diff pure move changed lines" "$(changed_lines)" ""
[ "$diff_rc" = 0 ] || show_diff
for dropped in caddy jellyfin seafile-redis grafana; do
  if trailer_lists "$dropped"; then pass; else fail "diff trailer does not list old-only service $dropped"; fi
done
if trailer_lists open-webui; then fail "diff trailer lists moved service open-webui"; else pass; fi
if printf '%s\n' "$diff_out" | grep -qF "$scratch"; then fail "diff output leaks scratch paths"; else pass; fi

sed -i.orig 's/container_name: open-webui$/container_name: open-webui-renamed/' "$work/apps/open-webui/compose.yaml"
run_diff homelab compose.yaml apps/open-webui/compose.yaml
check "diff renamed container exit" "$diff_rc" "1"
if changed_lines | grep -q '^-.*"open-webui"' && changed_lines | grep -q '^+.*"open-webui-renamed"'; then pass; else fail "diff does not show the container_name change"; show_diff; fi
mv "$work/apps/open-webui/compose.yaml.orig" "$work/apps/open-webui/compose.yaml"

cat >> "$work/apps/open-webui/compose.yaml" <<'EOF'
    ports:
      - 3000:8080
EOF
run_diff homelab compose.yaml apps/open-webui/compose.yaml
check "diff added port exit" "$diff_rc" "1"
if changed_lines | grep -q '^+.*3000'; then pass; else fail "diff does not show the added port"; show_diff; fi

cat > "$work/apps/open-webui/compose.yaml" <<'EOF'
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    volumes:
      - ${HOMELAB_DATA_DIR:?}/openwebui-moved:/app/backend/data
    restart: always
    networks:
      - homelab-network
EOF
run_diff homelab compose.yaml apps/open-webui/compose.yaml
check "diff moved bind exit" "$diff_rc" "1"
if changed_lines | grep -q '^+.*"<repo>/.data/openwebui-moved"' && changed_lines | grep -q '^-.*"<repo>/.data/open-webui/app/backend/data"'; then pass; else fail "diff does not show the bind move with <repo> paths"; show_diff; fi

cat > "$work/apps/open-webui/compose.yaml" <<EOF
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    volumes:
      - \${HOMELAB_DATA_DIR:?}/open-webui/app/backend/data:/app/backend/data
    restart: always
    networks:
      - homelab-network
  brand-new:
    image: docker.io/library/busybox:1.37.0@$digest
    container_name: brand-new
    networks:
      - homelab-network
EOF
run_diff homelab compose.yaml apps/open-webui/compose.yaml
check "diff new service exit" "$diff_rc" "1"
if changed_lines | grep -q '^+.*brand-new'; then pass; else fail "diff does not show the service missing from the old side"; show_diff; fi
reset_apps

mkdir -p "$work/apps/observability"
cat > "$work/apps/observability/compose.yaml" <<EOF
services:
  grafana-funnel:
    image: tailscale/tailscale:latest
    container_name: tailscale-funnel
    restart: unless-stopped
    hostname: otel-funnel
    env_file:
      - \${HOMELAB_SECRETS_DIR:?}/tailscale-funnel.env
    environment:
      - TS_STATE_DIR=/var/lib/tailscale
      - TS_SERVE_CONFIG=/config/serve.json
    volumes:
      - grafana-funnel:/var/lib/tailscale
      - $work/config/tailscale-serve.json:/config/serve.json:ro
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    networks:
      - homelab-network

volumes:
  grafana-funnel:
    driver: local
EOF
run_diff homelab compose.yaml apps/observability/compose.yaml
check "diff interpolated secret to env_file exit" "$diff_rc" "0"
check "diff interpolated secret to env_file changed lines" "$(changed_lines)" ""
[ "$diff_rc" = 0 ] || show_diff
if printf '%s\n' "$diff_out" | grep -qF "$work"; then fail "diff output leaks the workspace path"; else pass; fi

sed -i.orig '/TS_SERVE_CONFIG/d' "$work/apps/observability/compose.yaml"
run_diff homelab compose.yaml apps/observability/compose.yaml
check "diff dropped environment key exit" "$diff_rc" "1"
if changed_lines | grep -q '^-.*TS_SERVE_CONFIG'; then pass; else fail "diff does not show the dropped environment key"; show_diff; fi
if changed_lines | grep -q 'TS_AUTHKEY'; then fail "diff shows the env_file secret as changed"; show_diff; else pass; fi
reset_apps

mkdir -p "$work/apps/openseo"
git -C "$repo" show "$baseline:openseo/compose.yaml" > "$work/apps/openseo/compose.yaml"
run_diff openseo openseo/compose.yaml apps/openseo/compose.yaml
if [ "$diff_rc" -le 1 ]; then pass; else fail "diff openseo standalone render exit $diff_rc"; show_diff; fi
if changed_lines | grep -qE 'AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|RUSTFS_'; then fail "diff openseo shows storage secrets as changed"; show_diff; else pass; fi
rm -rf "$work/apps/openseo"
reset_apps

printf 'services:\n  oldside:\n    image: busybox:latest\n' > "$work/moved-after-baseline.yaml"
git -C "$work" add moved-after-baseline.yaml
git -C "$work" -c user.name=t -c user.email=t@t commit -q -m t
run_diff homelab moved-after-baseline.yaml apps/open-webui/compose.yaml
check "diff old path absent from $baseline" "$diff_rc" "2"

run_diff homelab compose.yaml apps/does-not-exist/compose.yaml
check "diff missing new file" "$diff_rc" "2"
run_diff homelab compose.yaml
check "diff wrong argument count" "$diff_rc" "2"
run_diff nope compose.yaml apps/open-webui/compose.yaml
check "diff unknown project" "$diff_rc" "2"

if [ "$ran" = 0 ]; then
  echo "no test cases ran"
  exit 1
fi
echo "$ran checks, $failures failed"
[ "$failures" = 0 ]
