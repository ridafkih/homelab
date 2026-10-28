#!/bin/sh
set -u

baseline=9af811a
edge_files="apps/caddy/compose.yaml apps/authentik/compose.yaml apps/ridash/compose.yaml"

for tool in docker-compose jq git awk diff; do
  command -v "$tool" >/dev/null 2>&1 || { echo "compose-edge: missing tool: $tool" >&2; exit 2; }
done

root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd -P)
cd "$root" || exit 2
git cat-file -e "$baseline^{commit}" 2>/dev/null || { echo "compose-edge: baseline $baseline is not in $root" >&2; exit 2; }

scratch=$(CDPATH='' cd -- "$(mktemp -d -t compose-edge.XXXXXX)" && pwd -P)
trap 'rm -rf "$scratch"' EXIT INT TERM

export DOCKER_HOST=unix:///nonexistent

failures=0
checks=0

pass() {
  checks=$((checks + 1))
}

fail() {
  checks=$((checks + 1))
  failures=$((failures + 1))
  printf 'fail: %s\n' "$1"
}

check() {
  label=$1
  shift
  if "$@" > "$scratch/check.out" 2>&1; then
    pass
  else
    fail "$label"
    awk '{ print "  | " $0 }' "$scratch/check.out" | head -40
  fi
}

refute() {
  label=$1
  shift
  if "$@" > "$scratch/check.out" 2>&1; then
    fail "$label"
    awk '{ print "  | " $0 }' "$scratch/check.out" | head -40
  else
    pass
  fi
}

expected_pins='{
  "caddy": "ghcr.io/caddybuilds/caddy-cloudflare:latest@sha256:9c398a17f826530b99e0a68e63ba85f341ddbadc9c2f23668a1aa8f58ce33fb8",
  "ridash-cloudflared": "cloudflare/cloudflared:latest@sha256:1b1d34d0a9c0bfca9de72db8460d328db3f19edd2b96169114e3e893a97bbe53",
  "authentik-cloudflared": "cloudflare/cloudflared:latest@sha256:1b1d34d0a9c0bfca9de72db8460d328db3f19edd2b96169114e3e893a97bbe53",
  "authentik-postgresql": "docker.io/library/postgres:16-alpine@sha256:0cefaabd882e42bcb2a2f3dc56d3ce4770560ba62fd7f197f1a2e008fd5731ab",
  "authentik-redis": "docker.io/library/redis:alpine@sha256:47b08295737773de3b711fb86f13ae802f5074e96a9a2d29f5f80164ac08c046",
  "authentik-server": "ghcr.io/goauthentik/server:2025.8.4@sha256:a10398480e7f8292dbcc27b64fe572f6abed6220bd40f4b6d28e9c12d4b78dca",
  "authentik-worker": "ghcr.io/goauthentik/server:2025.8.4@sha256:a10398480e7f8292dbcc27b64fe572f6abed6220bd40f4b6d28e9c12d4b78dca"
}'

expected_services='{
  "apps/caddy/compose.yaml": ["caddy"],
  "apps/authentik/compose.yaml": ["authentik-cloudflared", "authentik-postgresql", "authentik-redis", "authentik-server", "authentik-worker"],
  "apps/ridash/compose.yaml": ["ridash-cloudflared"]
}'

expected_declared_networks='{
  "apps/caddy/compose.yaml": [],
  "apps/authentik/compose.yaml": ["authentik-network"],
  "apps/ridash/compose.yaml": ["ridash-network"]
}'

expected_env_files='{
  "caddy": ["caddy.env"],
  "ridash-cloudflared": ["ridash.env"],
  "authentik-cloudflared": ["authentik-tunnel.env"],
  "authentik-postgresql": ["authentik.env"],
  "authentik-redis": [],
  "authentik-server": ["authentik.env"],
  "authentik-worker": ["authentik.env"]
}'

authentik_app_env='["AUTHENTIK_POSTGRESQL__HOST", "AUTHENTIK_POSTGRESQL__NAME", "AUTHENTIK_POSTGRESQL__PASSWORD", "AUTHENTIK_POSTGRESQL__USER", "AUTHENTIK_REDIS__HOST", "AUTHENTIK_SECRET_KEY", "REQUESTS_CA_BUNDLE", "SSL_CERT_FILE"]'

caddyfile_without_dead_routes() {
  awk '
    /^[[:space:]]*@(pihole|ollama)[[:space:]]+host/ { skip = 1; next }
    skip && /^[[:space:]]*handle[[:space:]]+@(pihole|ollama)/ { next }
    skip && /^[[:space:]]*}[[:space:]]*$/ { skip = 0; next }
    skip { next }
    { print }
  '
}

non_blank() {
  awk 'NF > 0'
}

caddyfile_is_baseline_minus_dead_routes() {
  [ -f apps/caddy/Caddyfile ] || { echo "apps/caddy/Caddyfile is missing"; return 1; }
  git show "$baseline:config/Caddyfile" | caddyfile_without_dead_routes | non_blank > "$scratch/caddy.expected"
  non_blank < apps/caddy/Caddyfile > "$scratch/caddy.actual"
  diff -u "$scratch/caddy.expected" "$scratch/caddy.actual"
}

caddyfile_has_no_dead_routes() {
  [ -f apps/caddy/Caddyfile ] || { echo "apps/caddy/Caddyfile is missing"; return 1; }
  ! grep -niE 'ollama|pihole' apps/caddy/Caddyfile
}

caddyfile_moved_byte_identical_in_own_commit() {
  git show "$baseline:config/Caddyfile" > "$scratch/caddy.baseline"
  for commit in $(git log --format=%H -- apps/caddy/Caddyfile); do
    git show "$commit:apps/caddy/Caddyfile" > "$scratch/caddy.at" 2>/dev/null || continue
    if cmp -s "$scratch/caddy.baseline" "$scratch/caddy.at" && ! git cat-file -e "$commit:config/Caddyfile" 2>/dev/null; then
      return 0
    fi
  done
  echo "no commit holds apps/caddy/Caddyfile byte-identical to $baseline:config/Caddyfile with config/Caddyfile gone"
  return 1
}

no_floating_tag_in_history() {
  : > "$scratch/floating"
  for file in $edge_files; do
    for commit in $(git log --format=%H -- "$file"); do
      git show "$commit:$file" 2>/dev/null | grep -nE '^[[:space:]]*image:' | grep -v '@sha256:[0-9a-f]\{64\}' | sed "s|^|$commit $file: |" >> "$scratch/floating"
    done
  done
  cat "$scratch/floating"
  [ ! -s "$scratch/floating" ]
}

not_in_apps() {
  ! grep -rn -- "$1" apps/
}

source_render() {
  docker-compose -f "$1" config --no-interpolate --no-consistency --no-path-resolution --format json
}

source_layout() {
  status=0
  for file in $edge_files; do
    source_render "$file" > "$scratch/source.json" || { status=1; continue; }
    jq -e -n --arg file "$file" --slurpfile r "$scratch/source.json" \
      --argjson services "$expected_services" --argjson networks "$expected_declared_networks" '
      ($r[0].services // {} | keys) as $have_services
      | ($r[0].networks // {} | keys) as $have_networks
      | ($r[0].volumes // {} | keys) as $have_volumes
      | [
          (if $have_services != $services[$file] then "\($file): services \($have_services) != \($services[$file])" else empty end),
          (if $have_networks != $networks[$file] then "\($file): declares networks \($have_networks), expected \($networks[$file])" else empty end),
          (if $file == "apps/authentik/compose.yaml" and $have_volumes != ["authentik-database", "authentik-redis"] then "\($file): declares volumes \($have_volumes)" else empty end),
          (if $file != "apps/authentik/compose.yaml" and $have_volumes != [] then "\($file): declares volumes \($have_volumes)" else empty end)
        ]
      | if length == 0 then true else (.[] | . + "\n" | stderr) | false end
    ' >/dev/null 2> "$scratch/layout.err" || { cat "$scratch/layout.err"; status=1; }
  done
  return $status
}

source_env_files_and_pins() {
  for file in $edge_files; do source_render "$file" || return 1; done | jq -s '[.[].services // {}] | add // {}' > "$scratch/sources.json"
  jq -e --argjson envs "$expected_env_files" --argjson pins "$expected_pins" '
    . as $s
    | [
        ($pins | keys[] as $svc
          | if ($s | has($svc) | not) then "\($svc): missing"
            else
              (if $s[$svc].image != $pins[$svc] then "\($svc): image \($s[$svc].image) != \($pins[$svc])" else empty end),
              (($s[$svc].env_file // []) | if type == "array" then . else [.] end | map(if type == "object" then .path else . end)) as $have
              | ($envs[$svc] | map("${HOMELAB_SECRETS_DIR:?}/" + .)) as $want
              | if $have != $want then "\($svc): env_file \($have) != \($want)" else empty end
            end)
      ]
    | if length == 0 then true else (.[] | . + "\n" | stderr) | false end
  ' "$scratch/sources.json" >/dev/null 2> "$scratch/pins.err" || { cat "$scratch/pins.err"; return 1; }
}

lint_together() {
  sh scripts/compose-lint.sh --env-file homelab.env $edge_files
}

lint_one() {
  sh scripts/compose-lint.sh --env-file homelab.env "$1"
}

diff_runs() {
  sh migration/compose-diff.sh homelab compose.yaml "$1" > "$scratch/diff.out" 2>&1
  status=$?
  cat "$scratch/diff.out"
  [ "$status" -le 1 ]
}

old_dir="$scratch/old"
data_dir="$old_dir/.data"
secrets_dir="$scratch/secrets"
mkdir -p "$old_dir" "$data_dir" "$secrets_dir"
git show "$baseline:compose.yaml" > "$old_dir/compose.yaml"

{
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' homelab.env | grep -vE '^HOMELAB_(DATA|SECRETS)_DIR='
  awk -F '\t' '{ n = split($3, p, "/"); print p[n] "=dummy-" $3 }' secrets/keys.tsv
  sed 's/\$\$//g' "$old_dir/compose.yaml" | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*' | cut -c3- | sed 's/.*/&=dummy-&/'
} | awk -F '=' '!seen[$1]++' > "$old_dir/.env"

grep -E '^[A-Za-z_][A-Za-z0-9_]*=' homelab.env | grep -vE '^HOMELAB_(DATA|SECRETS)_DIR=' > "$scratch/new.env"
awk -F '\t' '$1 != "-" && $2 != "-" { print $2 "='"'"'dummy-" $3 "'"'"'" > (dir "/" $1) }' dir="$secrets_dir" secrets/keys.tsv
template_values=$(awk -F '\t' '$1 != "-" && $2 != "-" { print $1 "\t" $2 "\tdummy-" $3 }' secrets/keys.tsv | jq -R -s '
  split("\n") | map(select(length > 0) | split("\t")) | reduce .[] as $r ({}; .[$r[0]][$r[1]] = $r[2])')

render_new() {
  env_file=$1
  shift
  env -i PATH="$PATH" HOME="$HOME" DOCKER_HOST="$DOCKER_HOST" "$@" \
    docker-compose -p homelab --env-file "$env_file" -f "$root/compose.yaml" config --format json
}

env -i PATH="$PATH" HOME="$HOME" DOCKER_HOST="$DOCKER_HOST" HOMELAB_DATA_DIR="$data_dir" \
  docker-compose -p homelab --env-file "$old_dir/.env" -f "$old_dir/compose.yaml" config --format json > "$scratch/old.json" 2> "$scratch/old.err" || {
  cat "$scratch/old.err" >&2
  echo "compose-edge: cannot render $baseline:compose.yaml" >&2
  exit 2
}

render_new_ok() {
  render_new "$scratch/new.env" HOMELAB_DATA_DIR="$data_dir" HOMELAB_SECRETS_DIR="$secrets_dir" > "$scratch/new.json"
}

rendered_matches_baseline() {
  [ -s "$scratch/new.json" ] || { echo "no root render"; return 1; }
  jq -e -n --slurpfile old "$scratch/old.json" --slurpfile new "$scratch/new.json" \
    --arg olddir "$old_dir" --arg root "$root" \
    --argjson pins "$expected_pins" --argjson envs "$expected_env_files" \
    --argjson values "$template_values" --argjson app_env "$authentik_app_env" '
    def nets: (. // {}) | with_entries(select(.key != "local-network") | .value = ((.value // {}) | del(.gw_priority)));
    def moved: map(if .type == "bind" then .source |= (
        if . == ($olddir + "/config/Caddyfile") then $root + "/apps/caddy/Caddyfile"
        elif startswith($olddir + "/.authentik/") then $olddir + "/.data/authentik/" + .[($olddir + "/.authentik/" | length):]
        else . end) else . end);
    def rest: del(.image, .environment, .env_file, .volumes, .networks);
    $old[0] as $o | $new[0] as $n
    | [
        (if $n.name != "homelab" then "project name \($n.name) != homelab" else empty end),
        ($pins | keys[] as $svc
          | $o.services[$svc] as $os | $n.services[$svc] as $ns
          | if $ns == null then "\($svc): not rendered by the root compose.yaml"
            else
              (if $ns.container_name != $os.container_name then "\($svc): container_name \($ns.container_name) != \($os.container_name)" else empty end),
              (if ($ns.image | startswith($os.image + "@sha256:") | not) then "\($svc): image \($ns.image) is not \($os.image)@sha256:..." else empty end),
              (($ns.volumes // []) as $nv | ($os.volumes // [] | moved) as $ov
                | if $nv != $ov then "\($svc): volumes differ beyond the path moves\n  old \($ov | tojson)\n  new \($nv | tojson)" else empty end),
              (($ns.networks | nets) as $nn | ($os.networks | nets) as $on
                | if $nn != $on then "\($svc): networks \($nn | tojson) != \($on | tojson) after dropping local-network and gw_priority" else empty end),
              (($ns | rest) as $nr | ($os | rest) as $or
                | if $nr != $or then "\($svc): other fields differ\n  old \($or | tojson)\n  new \($nr | tojson)" else empty end),
              (($ns.environment // {}) as $ne | ($os.environment // {}) as $oe
                | (if ($svc == "authentik-server" or $svc == "authentik-worker") then $app_env else ($oe | keys) end) as $keep
                | ([$envs[$svc][] | $values[.] // {}] | add // {}) as $extra
                | (($keep + ($extra | keys)) | unique) as $allowed
                | ($keep[] | select($ne[.] != $oe[.]) | "\($svc): environment \(.) is \($ne[.] | tojson), baseline \($oe[.] | tojson)"),
                  ($extra | keys[] | select($ne[.] != $extra[.]) | "\($svc): env_file key \(.) is \($ne[.] | tojson), expected \($extra[.] | tojson)"),
                  ($ne | keys[] | select(. as $k | $allowed | index($k) | not) | "\($svc): unexpected environment key \(.)"))
            end),
        ("homelab-network", "ridash-network" | . as $k
          | if $n.networks[$k] != $o.networks[$k] then "network \($k): \($n.networks[$k] | tojson) != \($o.networks[$k] | tojson)" else empty end),
        (($o.networks["authentik-network"] + {ipam: {config: [{subnet: "172.19.0.0/16", gateway: "172.19.0.1"}]}}) as $want
          | if $n.networks["authentik-network"] != $want then "network authentik-network: \($n.networks["authentik-network"] | tojson) != \($want | tojson)" else empty end),
        (if ($n.networks // {} | has("local-network")) then "local-network is still rendered" else empty end),
        ($n.networks // {} | to_entries[] | select(.value.driver == "macvlan") | "network \(.key) is a macvlan"),
        ("authentik-database", "authentik-redis" | . as $k
          | if $n.volumes[$k] != $o.volumes[$k] then "volume \($k): \($n.volumes[$k] | tojson) != \($o.volumes[$k] | tojson)" else empty end)
      ]
    | if length == 0 then true else (.[] | . + "\n" | stderr) | false end
  ' >/dev/null 2> "$scratch/match.err" || { cat "$scratch/match.err"; return 1; }
}

without_line() {
  grep -v "^$1=" "$scratch/new.env" > "$scratch/without-$1.env"
  echo "$scratch/without-$1.env"
}

renders_without_var() {
  render_new "$(without_line "$1")" HOMELAB_DATA_DIR="$data_dir" HOMELAB_SECRETS_DIR="$secrets_dir"
}

renders_without_secrets_dir() {
  render_new "$scratch/new.env" HOMELAB_DATA_DIR="$data_dir"
}

renders_without_data_dir() {
  render_new "$scratch/new.env" HOMELAB_SECRETS_DIR="$secrets_dir"
}

renders_without_template() {
  partial="$scratch/partial-$1"
  rm -rf "$partial"
  cp -R "$secrets_dir" "$partial"
  rm -f "$partial/$1"
  render_new "$scratch/new.env" HOMELAB_DATA_DIR="$data_dir" HOMELAB_SECRETS_DIR="$partial"
}

check "config/Caddyfile is deleted" test ! -e config/Caddyfile
check "apps/caddy/Caddyfile has no ollama or pihole routes" caddyfile_has_no_dead_routes
check "apps/caddy/Caddyfile is $baseline:config/Caddyfile minus the @pihole and @ollama blocks" caddyfile_is_baseline_minus_dead_routes
check "the Caddyfile move is a byte-identical rename in its own commit (0005 rule 6)" caddyfile_moved_byte_identical_in_own_commit
check "grep -r local-network apps/ returns nothing" not_in_apps local-network
check "no gw_priority under apps/" not_in_apps gw_priority
check "no macvlan under apps/" not_in_apps macvlan
check "edge files define exactly their services, networks and volumes" source_layout
check "edge images are the live tag@sha256 pins and env_files are the rendered templates" source_env_files_and_pins
check "no commit carries a floating edge image tag (0006 rule 3)" no_floating_tag_in_history
check "compose-lint passes on the three edge files together" lint_together
for file in $edge_files; do
  check "compose-lint passes on $file alone" lint_one "$file"
  check "compose-diff runs on $file (exit 0 or 1)" diff_runs "$file"
done
check "the root compose.yaml renders with homelab.env and every template" render_new_ok
check "rendered edge services differ from $baseline only by pins, env_file, macvlan removal, ipam and path moves" rendered_matches_baseline
for var in CADDY_DOMAIN CADDY_HOST_MACHINE_HOSTNAME AUTHENTIK_POSTGRESQL__NAME AUTHENTIK_POSTGRESQL__HOST AUTHENTIK_REDIS__HOST; do
  refute "the root render fails fast without $var" renders_without_var "$var"
done
refute "the root render fails fast without HOMELAB_SECRETS_DIR" renders_without_secrets_dir
refute "the root render fails fast without HOMELAB_DATA_DIR" renders_without_data_dir
for template in caddy.env authentik.env authentik-tunnel.env ridash.env; do
  refute "the root render fails fast without $template" renders_without_template "$template"
done

printf '%s checks, %s failed\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
