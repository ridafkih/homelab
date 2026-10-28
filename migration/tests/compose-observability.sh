#!/bin/sh
set -eu

baseline=9af811a
app=apps/observability
compose_file=$app/compose.yaml

usage() {
  echo "usage: compose-observability.sh [--live SSH_HOST]" >&2
  exit 2
}

live_host=""
while [ $# -gt 0 ]; do
  case $1 in
    --live)
      [ $# -ge 2 ] || usage
      live_host=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

for tool in docker-compose jq git diff awk; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool" >&2; exit 2; }
done

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
repo=$(CDPATH='' cd -- "$repo" && pwd -P)
git -C "$repo" cat-file -e "$baseline^{commit}" 2>/dev/null || { echo "baseline $baseline is not in $repo" >&2; exit 2; }
[ -f "$repo/secrets/keys.tsv" ] || { echo "missing $repo/secrets/keys.tsv" >&2; exit 2; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/compose-observability.XXXXXX")
trap 'rm -rf "$scratch"' EXIT INT TERM
scratch=$(CDPATH='' cd -- "$scratch" && pwd -P)

export DOCKER_HOST="unix://$scratch/no-docker-daemon.sock"

ran=0
failures=0
pass() { ran=$((ran + 1)); }
fail() { ran=$((ran + 1)); failures=$((failures + 1)); echo "FAIL: $1"; }
check() { if [ "$2" = "$3" ]; then pass; else fail "$1: expected [$3], got [$2]"; fi; }

services="otel-collector tempo prometheus loki grafana grafana-funnel signoz-init-clickhouse signoz-zookeeper signoz-clickhouse signoz-telemetrystore-migrator signoz signoz-otel-collector"
volumes="grafana grafana-funnel loki prometheus signoz-clickhouse signoz-clickhouse-scripts signoz-sqlite signoz-zookeeper tempo"
configs="otel-collector.yaml tempo.yaml loki.yaml prometheus.yml grafana-datasources.yaml tailscale-serve.json signoz/clickhouse-cluster.xml signoz/clickhouse-config.xml signoz/clickhouse-custom-function.xml signoz/clickhouse-users.xml signoz/otel-collector-opamp.yaml signoz/otel-collector.yaml"

cat > "$scratch/pins.tsv" <<'EOF'
otel-collector	otel-collector	otel/opentelemetry-collector-contrib:latest@sha256:340c9ca6a36617084c6661bdc4f0fe92b7cda5a805d61673ec8db375fddc522b
tempo	tempo	grafana/tempo:2.6.1@sha256:ef4384fce6e8ad22b95b243d8fc165628cda655376fd50e7850536ad89d71d50
prometheus	prometheus	prom/prometheus:latest@sha256:fa3302279710be2f21a8301ec17a8b4f2301fd829bd113839b3b6b02b6f191a2
loki	loki	grafana/loki:latest@sha256:0db216b630ae1f348a1584c67f3cead8b4c1fc839169a39501db664744158e28
grafana	grafana	grafana/grafana:latest@sha256:488984b716c0862639f91a698adbe2862677a5a07bad42da5f03f3030883b205
grafana-funnel	tailscale-funnel	tailscale/tailscale:latest@sha256:b11583ad2e93e4671128538c88cf11f460444a5d7e449311dd1933a400ab849d
signoz-init-clickhouse	signoz-init-clickhouse	clickhouse/clickhouse-server:25.12.5@sha256:cacf32d6884291dc2ff5e0156a97f46fc53ff7c929a7906d114e268a929dfd3a
signoz-zookeeper	signoz-zookeeper	signoz/zookeeper:3.7.1@sha256:fcc4a3288154ccaa3bdb5ae6dc10180c084d29a8a6a26b62ac8e30a8940dc2e6
signoz-clickhouse	signoz-clickhouse	clickhouse/clickhouse-server:25.12.5@sha256:cacf32d6884291dc2ff5e0156a97f46fc53ff7c929a7906d114e268a929dfd3a
signoz-telemetrystore-migrator	signoz-telemetrystore-migrator	signoz/signoz-otel-collector:v0.144.8@sha256:6d1a59bc553e041014597eff0970608948c5c7447aaa984c4d109f2bc9f4062c
signoz	signoz	signoz/signoz:v0.138.0@sha256:0061009f21bf976a5374b6f73f98aa96f6f335d3ac753d6a792c6b3dc91a2328
signoz-otel-collector	signoz-otel-collector	signoz/signoz-otel-collector:v0.144.8@sha256:6d1a59bc553e041014597eff0970608948c5c7447aaa984c4d109f2bc9f4062c
EOF
pins_json=$(jq -Rn '[inputs | split("\t") | {key: .[0], value: .[2]}] | from_entries' < "$scratch/pins.tsv")

sorted_json() { printf '%s\n' $1 | LC_ALL=C sort | jq -Rn -c '[inputs]'; }
services_json=$(sorted_json "$services")
volumes_json=$(sorted_json "$volumes")

renames="$scratch/renames"
for f in $configs; do printf 'R100\tconfig/%s\t%s/config/%s\n' "$f" "$app" "$f"; done | LC_ALL=C sort > "$renames"

for f in $configs; do
  [ ! -e "$repo/config/$f" ] && pass || fail "config/$f still exists in the working tree"
  if git -C "$repo" ls-files --error-unmatch "config/$f" >/dev/null 2>&1; then fail "config/$f is still tracked"; else pass; fi
  expected=$(git -C "$repo" rev-parse "$baseline:config/$f")
  check "HEAD blob of $app/config/$f equals $baseline:config/$f" "$(git -C "$repo" rev-parse -q --verify "HEAD:$app/config/$f" 2>/dev/null || echo missing)" "$expected"
  if [ -f "$repo/$app/config/$f" ]; then
    check "working tree $app/config/$f is byte-identical" "$(git -C "$repo" hash-object "$app/config/$f")" "$expected"
  else
    fail "$app/config/$f is missing from the working tree"
  fi
  check "git diff -M shows config/$f renamed at 100%" \
    "$(git -C "$repo" diff -M --name-status "$baseline" HEAD -- "config/$f" "$app/config/$f")" \
    "$(printf 'R100\tconfig/%s\t%s/config/%s' "$f" "$app" "$f")"
done

check "$app/config holds exactly the twelve moved files" \
  "$(git -C "$repo" ls-files -- "$app/config" | LC_ALL=C sort | tr '\n' ' ')" \
  "$(for f in $configs; do echo "$app/config/$f"; done | LC_ALL=C sort | tr '\n' ' ')"

rename_commit=""
for c in $(git -C "$repo" rev-list --no-merges "$baseline..HEAD" -- config "$app/config"); do
  git -C "$repo" diff-tree -r -M --no-commit-id --name-status "$c" | LC_ALL=C sort > "$scratch/commit-renames"
  if diff -q "$renames" "$scratch/commit-renames" >/dev/null; then rename_commit=$c; break; fi
done
[ -n "$rename_commit" ] && pass || fail "no commit since $baseline holds exactly the twelve 100% renames and nothing else"

if [ -f "$repo/$compose_file" ]; then
  if grep -n ':-' "$repo/$compose_file" >/dev/null; then fail "$compose_file contains a ':-' fallback"; else pass; fi
  if grep -nE 'SIGNOZ_[A-Z_]*VERSION' "$repo/$compose_file" >/dev/null; then fail "$compose_file still references SIGNOZ_*VERSION"; else pass; fi
  if grep -nE '^[[:space:]]*#' "$repo/$compose_file" >/dev/null; then fail "$compose_file has comment lines"; else pass; fi
  for secret in GRAFANA_ADMIN GF_SECURITY_ADMIN TS_AUTHKEY SIGNOZ_JWT_SECRET SIGNOZ_TOKENIZER_JWT_SECRET OTEL_AUTH_TOKEN; do
    if grep -n "$secret" "$repo/$compose_file" >/dev/null; then fail "$compose_file names the secret $secret"; else pass; fi
  done
  if grep -nE '^[[:space:]]*(-[[:space:]]*)?(env_file:[[:space:]]*)?\.env[[:space:]]*$' "$repo/$compose_file" >/dev/null; then fail "$compose_file still passes the whole .env"; else pass; fi
  if grep -qE '^name:' "$repo/$compose_file"; then fail "$compose_file sets name:"; else pass; fi
else
  fail "$compose_file is missing"
fi

raw="$scratch/raw.json"
if docker-compose -f "$repo/$compose_file" config --no-interpolate --no-consistency --no-path-resolution --format json > "$raw" 2> "$scratch/raw.err"; then
  pass
  check "services in $compose_file" "$(jq -c '.services // {} | keys' "$raw")" "$services_json"
  check "volumes declared in $compose_file" "$(jq -c '.volumes // {} | keys' "$raw")" "$volumes_json"
  check "networks declared in $compose_file" "$(jq -c '.networks // {} | keys' "$raw")" '["signoz-network"]'
  for svc in $services; do
    case $svc in
      otel-collector) want='["${HOMELAB_SECRETS_DIR:?}/otel.env"]' ;;
      grafana) want='["${HOMELAB_SECRETS_DIR:?}/grafana.env"]' ;;
      grafana-funnel) want='["${HOMELAB_SECRETS_DIR:?}/tailscale-funnel.env"]' ;;
      signoz) want='["${HOMELAB_SECRETS_DIR:?}/signoz.env"]' ;;
      *) want='[]' ;;
    esac
    check "env_file of $svc" \
      "$(jq -c --arg s "$svc" '[.services[$s].env_file // [] | if type == "array" then .[] else . end | if type == "object" then .path else . end]' "$raw")" \
      "$want"
    check "image of $svc is the running digest pin" \
      "$(jq -r --arg s "$svc" '.services[$s].image // "missing"' "$raw")" \
      "$(printf '%s' "$pins_json" | jq -r --arg s "$svc" '.[$s]')"
  done
  check "prometheus retention is required, not defaulted" \
    "$(jq -r '[.services.prometheus.command // [] | .[] | select(startswith("--storage.tsdb.retention.time="))] | join(" ")' "$raw")" \
    '--storage.tsdb.retention.time=${PROMETHEUS_RETENTION:?}'
  check "grafana secrets are not inline environment entries" \
    "$(jq -c '[.services.grafana.environment // [] | if type == "object" then keys[] else .[] | sub("=.*"; "") end | select(startswith("GF_SECURITY_ADMIN"))]' "$raw")" '[]'
  check "grafana-funnel TS_AUTHKEY is not an inline environment entry" \
    "$(jq -c '[.services["grafana-funnel"].environment // [] | if type == "object" then keys[] else .[] | sub("=.*"; "") end | select(. == "TS_AUTHKEY")]' "$raw")" '[]'
  check "signoz JWT secret is not an inline environment entry" \
    "$(jq -c '[.services.signoz.environment // [] | if type == "object" then keys[] else .[] | sub("=.*"; "") end | select(. == "SIGNOZ_TOKENIZER_JWT_SECRET")]' "$raw")" '[]'
  check "otel-collector has no inline environment" \
    "$(jq -c '.services["otel-collector"].environment // [] | length' "$raw")" '0'
else
  fail "$compose_file does not render: $(cat "$scratch/raw.err")"
fi

while read -r svc _ pin; do
  old_image=$(git -C "$repo" show "$baseline:compose.yaml" | awk -v s="  $svc:" '$0 == s { on = 1; next } on && /^  [^ ]/ { on = 0 } on && /^    image:/ { sub(/^    image: */, ""); print; exit }')
  old_image=$(printf '%s' "$old_image" | sed -E 's/\$\{SIGNOZ_[A-Z_]*VERSION:-([^}]*)\}/\1/')
  check "pin of $svc keeps the baseline repo and tag" "${pin%%@*}" "$old_image"
done < "$scratch/pins.tsv"

keys="$repo/secrets/keys.tsv"
secrets_dir="$scratch/secrets"
data_dir="$scratch/data"
mkdir -p "$secrets_dir" "$data_dir" "$scratch/old"
awk -F '\t' '$1 != "-" && $2 != "-" { print $2 "='"'"'dummy-" $3 "'"'"'" > (dir "/" $1) }' dir="$secrets_dir" "$keys"

env_file="$scratch/env"
{
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$repo/homelab.env" | grep -vE '^HOMELAB_(DATA|SECRETS)_DIR='
  awk -F '\t' '{ n = split($3, p, "/"); print p[n] "=dummy-" $3 }' "$keys"
} | awk -F '=' '!seen[$1]++' > "$env_file"

git -C "$repo" show "$baseline:compose.yaml" > "$scratch/old/compose.yaml"
cp "$env_file" "$scratch/old/.env"

awk -v inc="$repo/$compose_file" '
  /^include:/ { print; print "  - " inc; skip = 1; next }
  skip && /^  *- / { next }
  { skip = 0; print }
' "$repo/compose.yaml" > "$scratch/root.yaml"

render() {
  env -i PATH="$PATH" HOME="$HOME" DOCKER_HOST="$DOCKER_HOST" \
    HOMELAB_DATA_DIR="$data_dir" HOMELAB_SECRETS_DIR="$secrets_dir" \
    docker-compose -p homelab --env-file "$1" -f "$2" config --format json
}

render "$env_file" "$scratch/old/compose.yaml" > "$scratch/old.json" 2> "$scratch/old.err" || { echo "cannot render $baseline:compose.yaml: $(cat "$scratch/old.err")" >&2; exit 2; }

if render "$env_file" "$scratch/root.yaml" > "$scratch/new.json" 2> "$scratch/new.err"; then
  pass
  compare='
    def rebase($prefix): if (.volumes // null) == null then . else .volumes |= map(if .type == "bind" and (.source | startswith($prefix)) then .source = "CFG/" + .source[($prefix | length):] else . end) end;
    ($old.services[$svc] // {} | del(.image) | rebase($oldcfg)) as $o
    | (.services[$svc] // {} | del(.image) | rebase($newcfg)) as $n
    | if $svc == "otel-collector" then ($o | del(.environment)) == ($n | del(.environment)) else $o == $n end
  '
  for svc in $services; do
    same=$(jq --slurpfile oldfile "$scratch/old.json" --arg svc "$svc" --arg oldcfg "$scratch/old/config/" --arg newcfg "$repo/$app/config/" \
      "\$oldfile[0] as \$old | $compare" "$scratch/new.json" 2>/dev/null || echo error)
    if [ "$same" = true ]; then
      pass
    else
      fail "$svc renders differently from $baseline beyond image, env_file and config path"
      jq -S --arg s "$svc" '.services[$s] // {}' "$scratch/old.json" > "$scratch/o.$svc.json"
      jq -S --arg s "$svc" '.services[$s] // {}' "$scratch/new.json" > "$scratch/n.$svc.json"
      diff -u "$scratch/o.$svc.json" "$scratch/n.$svc.json" | sed -n '3,40p' || true
    fi
    check "rendered image of $svc" "$(jq -r --arg s "$svc" '.services[$s].image // "missing"' "$scratch/new.json")" "$(printf '%s' "$pins_json" | jq -r --arg s "$svc" '.[$s]')"
  done
  check "otel-collector receives only OTEL_AUTH_TOKEN" \
    "$(jq -c '.services["otel-collector"].environment // {}' "$scratch/new.json")" \
    '{"OTEL_AUTH_TOKEN":"dummy-otel/OTEL_AUTH_TOKEN"}'
  check "grafana receives its admin credentials from grafana.env" \
    "$(jq -c '.services.grafana.environment // {} | {GF_SECURITY_ADMIN_USER, GF_SECURITY_ADMIN_PASSWORD}' "$scratch/new.json")" \
    '{"GF_SECURITY_ADMIN_USER":"dummy-grafana/GRAFANA_ADMIN_USER","GF_SECURITY_ADMIN_PASSWORD":"dummy-grafana/GRAFANA_ADMIN_PASSWORD"}'
  check "grafana-funnel receives TS_AUTHKEY from tailscale-funnel.env" \
    "$(jq -r '.services["grafana-funnel"].environment.TS_AUTHKEY // "missing"' "$scratch/new.json")" 'dummy-tailscale-funnel/TS_AUTHKEY'
  check "signoz receives its JWT secret from signoz.env" \
    "$(jq -r '.services.signoz.environment.SIGNOZ_TOKENIZER_JWT_SECRET // "missing"' "$scratch/new.json")" 'dummy-signoz/SIGNOZ_JWT_SECRET'
  check "prometheus retention renders from homelab.env" \
    "$(jq -r '[.services.prometheus.command // [] | .[] | select(startswith("--storage.tsdb.retention.time="))] | join(" ")' "$scratch/new.json")" \
    "--storage.tsdb.retention.time=$(sed -n 's/^PROMETHEUS_RETENTION=//p' "$repo/homelab.env")"
  check "otel-collector ports" "$(jq -c '[.services["otel-collector"].ports // [] | .[] | "\(.published):\(.target)"]' "$scratch/new.json")" '["4317:4317","4318:4318"]'
  check "signoz-otel-collector ports" "$(jq -c '[.services["signoz-otel-collector"].ports // [] | .[] | "\(.published):\(.target)"]' "$scratch/new.json")" '["4327:4317","4328:4318"]'
  for svc in $services; do
    check "container_name of $svc" "$(jq -r --arg s "$svc" '.services[$s].container_name // "missing"' "$scratch/new.json")" "$(jq -r --arg s "$svc" '.services[$s].container_name' "$scratch/old.json")"
  done
  for v in $volumes; do
    check "volume $v resolves as before" "$(jq -c --arg v "$v" '.volumes[$v] // "missing"' "$scratch/new.json")" "$(jq -c --arg v "$v" '.volumes[$v]' "$scratch/old.json")"
  done
  check "rendered volume names" "$(jq -c '[.volumes // {} | .[] | .name] | sort' "$scratch/new.json")" "$(printf '%s\n' $volumes | sed 's/^/homelab_/' | LC_ALL=C sort | jq -Rn -c '[inputs]')"
  for n in homelab-network signoz-network; do
    check "network $n resolves as before" "$(jq -c --arg n "$n" '.networks[$n] // "missing"' "$scratch/new.json")" "$(jq -c --arg n "$n" '.networks[$n]' "$scratch/old.json")"
  done
  check "homelab-network subnet" "$(jq -r '.networks["homelab-network"].name + " " + (.networks["homelab-network"].ipam.config[0].subnet // "")' "$scratch/new.json")" 'homelab_homelab-network 172.20.0.0/16'
  check "signoz-network name" "$(jq -r '.networks["signoz-network"].name // "missing"' "$scratch/new.json")" 'homelab_signoz-network'
else
  fail "the root include with $compose_file does not render: $(cat "$scratch/new.err")"
fi

grep -v '^PROMETHEUS_RETENTION=' "$env_file" > "$scratch/env-no-retention"
if render "$scratch/env-no-retention" "$scratch/root.yaml" > /dev/null 2> "$scratch/neg.err"; then
  fail "rendering without PROMETHEUS_RETENTION succeeds; it must fail fast"
else
  grep -q PROMETHEUS_RETENTION "$scratch/neg.err" && pass || fail "rendering without PROMETHEUS_RETENTION failed for another reason: $(cat "$scratch/neg.err")"
fi

for template in grafana.env otel.env signoz.env tailscale-funnel.env; do
  mv "$secrets_dir/$template" "$scratch/held"
  if render "$env_file" "$scratch/root.yaml" > /dev/null 2> "$scratch/neg.err"; then
    fail "rendering with $template missing succeeds; it must fail fast"
  else
    grep -q "$template" "$scratch/neg.err" && pass || fail "rendering with $template missing failed for another reason: $(cat "$scratch/neg.err")"
  fi
  mv "$scratch/held" "$secrets_dir/$template"
done

lint_status=0
(cd "$repo" && sh scripts/compose-lint.sh --env-file homelab.env compose.yaml "$compose_file") > "$scratch/lint.out" 2>&1 || lint_status=$?
check "compose-lint.sh on the root and $compose_file: $(cat "$scratch/lint.out")" "$lint_status" 0

diff_status=0
(cd "$repo" && sh migration/compose-diff.sh homelab compose.yaml "$compose_file") > "$scratch/diff.out" 2> "$scratch/diff.err" || diff_status=$?
if [ "$diff_status" -le 1 ]; then
  pass
  sed -n '/^Services in /q;p' "$scratch/diff.out" | awk '/^(---|\+\+\+|@@)/ { next } /^[-+]/ { print }' | sed 's/,$//' > "$scratch/diff.lines"
  awk '{ sign = substr($0, 1, 1); body = substr($0, 2); if (sign == "-") minus[body]++; else plus[body]++; order[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        line = order[i]; sign = substr(line, 1, 1); body = substr(line, 2)
        if (sign == "-" && plus[body] > 0) { plus[body]--; continue }
        if (sign == "+" && minus[body] > 0) { minus[body]--; continue }
        print line
      }
    }' "$scratch/diff.lines" > "$scratch/diff.net"
  bad=$(awk -v app="$app" '
    /^-[[:space:]]*"image": "[^"@]*"$/ { next }
    /^\+[[:space:]]*"image": "[^"@]+:[^"@]+@sha256:[0-9a-f]{64}"$/ { next }
    /^-[[:space:]]*"source": "<repo>\/config\// { next }
    $0 ~ "^\\+[[:space:]]*\"source\": \"<repo>/" app "/config/" { next }
    /^-[[:space:]]*"[A-Za-z_][A-Za-z0-9_]*": "[^"]*"$/ { next }
    { print }
  ' "$scratch/diff.net")
  check "compose-diff.sh shows only pins, env_file and path changes" "$bad" ""
  check "compose-diff.sh shows a pinned image for every service" "$(grep -cE '^\+[[:space:]]*"image": ".*@sha256:' "$scratch/diff.net" || true)" 12
  check "compose-diff.sh shows the twelve config path moves" "$(grep -cE "^\\+[[:space:]]*\"source\": \"<repo>/$app/config/" "$scratch/diff.net" || true)" 12
else
  fail "compose-diff.sh exited $diff_status: $(cat "$scratch/diff.err")"
fi

if [ -n "$live_host" ]; then
  containers=$(cut -f 2 "$scratch/pins.tsv" | tr '\n' ' ')
  ssh -n -o BatchMode=yes "$live_host" "for c in $containers; do printf '%s\t' \"\$c\"; docker image inspect -f '{{json .RepoDigests}}' \"\$(docker inspect -f '{{.Image}}' \"\$c\")\"; done" > "$scratch/live.tsv" 2> "$scratch/live.err" || true
  while read -r svc container pin; do
    running=$(awk -F '\t' -v c="$container" '$1 == c { print $2 }' "$scratch/live.tsv" | jq -r --arg r "${pin%%:*}" '.[] | select(startswith($r + "@"))' 2>/dev/null | head -n 1)
    check "pin of $svc matches the running $container on $live_host" "${running#*@}" "${pin#*@}"
  done < "$scratch/pins.tsv"
fi

echo "$ran checks, $failures failed"
[ "$failures" -eq 0 ]
