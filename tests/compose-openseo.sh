#!/bin/sh
set -eu

for tool in docker-compose jq git diff gitleaks; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool"; exit 2; }
done

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$repo"

scratch=$(mktemp -d "${TMPDIR:-/tmp}/compose-openseo.XXXXXX")
trap 'rm -rf "$scratch"' EXIT INT TERM

export DOCKER_HOST="unix://$scratch/no-docker-daemon.sock"

compose_file=apps/openseo/compose.yaml
committed_env=apps/openseo/openseo.env
keys=secrets/keys.tsv

openseo_image=ghcr.io/every-app/open-seo-standalone:0.1.19@sha256:6e774cc3acb679d9aa7303a1c1851267312e828bbb5c0208dbafdcca2ba7337e
storage_image=rustfs/rustfs:1.0.3@sha256:9ca9559533b537d10482fe923288b676ad08f92a7069d9a17327fbae3cab688b
web_image=nginx:1.28-alpine@sha256:a8b39bd9cf0f83869a2162827a0caf6137ddf759d50a171451b335cecc87d236

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

if [ -e openseo ]; then fail "the top-level openseo directory still exists"; else pass; fi
check "tracked files under openseo/" "$(git ls-files -- openseo | tr '\n' ' ')" ""

for path in "$compose_file" "$committed_env"; do
  if [ -f "$path" ]; then pass; else fail "$path is missing"; fi
  check "$path is tracked" "$(git ls-files -- "$path")" "$path"
done
[ -f "$compose_file" ] && [ -f "$committed_env" ] || finish

check "comment lines in $compose_file" "$(grep -c '^[[:space:]]*#' "$compose_file" || true)" "0"
check "comment lines in $committed_env" "$(grep -c '^[[:space:]]*#' "$committed_env" || true)" "0"
check "OPENSEO_IMAGE in $compose_file" "$(grep -c 'OPENSEO_IMAGE' "$compose_file" || true)" "0"
check "fallback interpolations in apps/openseo" "$(grep -rc ':-' apps/openseo | awk -F: '{ s += $NF } END { print s + 0 }')" "0"

check "keys in $committed_env" "$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$committed_env" | LC_ALL=C sort | tr '\n' ' ')" "AUTH_MODE BETTER_AUTH_URL OPENROUTER_MODEL "
check "non-key lines in $committed_env" "$(grep -cvE '^[A-Za-z_][A-Za-z0-9_]*=' "$committed_env" || true)" "0"
check "AUTH_MODE" "$(sed -n 's/^AUTH_MODE=//p' "$committed_env")" "local_noauth"
check "BETTER_AUTH_URL" "$(sed -n 's/^BETTER_AUTH_URL=//p' "$committed_env")" "https://open-seo.rida.sh"
check "OPENROUTER_MODEL (empty on the live box)" "$(sed -n 's/^OPENROUTER_MODEL=//p' "$committed_env")" ""

secret_keys=$(awk -F '\t' '$1 == "openseo.env" && $2 != "-" { print $2 }' "$keys" | LC_ALL=C sort)
check "openseo.env rows in $keys" "$(printf '%s\n' "$secret_keys" | tr '\n' ' ')" "CONTEXT_API_KEY DATAFORSEO_API_KEY GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET OPENROUTER_API_KEY STORAGE_ACCESS_KEY STORAGE_SECRET_KEY "
shared=$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$committed_env" | while read -r key; do printf '%s\n' "$secret_keys" | grep -qx "$key" && echo "$key"; done || true)
check "keys shared by $committed_env and the openseo.env template" "$shared" ""

expected_op() {
  case $1 in
    AUTH_MODE | BETTER_AUTH_URL) echo ":?" ;;
    OPENROUTER_MODEL) echo "?" ;;
    *)
      empty=$(awk -F '\t' -v k="$1" '$1 == "openseo.env" && $2 == k { print $4 }' "$keys")
      case $empty in
        deny) echo ":?" ;;
        allow) echo "?" ;;
        *) echo "not-allowed" ;;
      esac
      ;;
  esac
}

sed 's/\$\$//g' "$compose_file" | grep -oE '\$\{[^}]*\}?|\$[A-Za-z_][A-Za-z0-9_]*' > "$scratch/interpolations" || true
check "interpolations of AUTH_MODE, BETTER_AUTH_URL and OPENROUTER_MODEL" "$(grep -cE '^\$\{(AUTH_MODE|BETTER_AUTH_URL|OPENROUTER_MODEL)[^A-Za-z0-9_]' "$scratch/interpolations" || true)" "3"
for key in $secret_keys; do
  if grep -qE "^\\\$\\{${key}[^A-Za-z0-9_]" "$scratch/interpolations"; then pass; else fail "$key is never interpolated"; fi
done
while read -r raw; do
  name=$(printf '%s\n' "$raw" | sed -E 's/^\$\{?([A-Za-z_][A-Za-z0-9_]*).*/\1/')
  op=$(printf '%s\n' "$raw" | sed -E 's/^\$\{[A-Za-z_][A-Za-z0-9_]*(:?\?)?.*/\1/')
  case $raw in
    '${'*'}') ;;
    *) op="bare" ;;
  esac
  check "interpolation $raw" "$op" "$(expected_op "$name")"
done < "$scratch/interpolations"

dummy_secrets() {
  awk -F '\t' '$1 == "openseo.env" && $2 != "-" { print $2 "='"'"'dummy-" $3 "'"'"'" }' "$keys"
}

render() {
  env -i PATH="$PATH" HOME="$HOME" DOCKER_HOST="$DOCKER_HOST" \
    docker-compose -f "$compose_file" --env-file "$1" --env-file "$2" config --format json
}

mkdir -p "$scratch/rendered"
dummy_secrets > "$scratch/rendered/openseo.env"
if render "$committed_env" "$scratch/rendered/openseo.env" > "$scratch/render.json" 2> "$scratch/render.err"; then
  pass
else
  fail "render with the committed env and dummy secrets: $(cat "$scratch/render.err")"
  finish
fi

q() { jq -r "$1" "$scratch/render.json"; }
check "project name" "$(q .name)" "openseo"
check "services" "$(q '.services | keys | join(" ")')" "crawl-gateway init runtime storage web"
check "runtime image" "$(q .services.runtime.image)" "$openseo_image"
check "init image" "$(q .services.init.image)" "$openseo_image"
check "crawl-gateway image" "$(q '.services["crawl-gateway"].image')" "$openseo_image"
check "storage image" "$(q .services.storage.image)" "$storage_image"
check "web image" "$(q .services.web.image)" "$web_image"
check "volume names" "$(q '[.volumes[].name] | sort | join(" ")')" "openseo_config openseo_runtime openseo_storage openseo_web-config"
check "homelab network name" "$(q .networks.homelab.name)" "homelab_homelab-network"
check "homelab network is external" "$(q .networks.homelab.external)" "true"
check "web alias on homelab" "$(q '.services.web.networks.homelab.aliases | join(" ")')" "open-seo"
check "web publishes no port" "$(q '.services.web.ports // [] | length')" "0"
check "env_file entries" "$(q '[.services[] | .env_file // empty] | length')" "0"
check "storage RUSTFS_ACCESS_KEY" "$(q .services.storage.environment.RUSTFS_ACCESS_KEY)" "dummy-openseo/STORAGE_ACCESS_KEY"
check "storage RUSTFS_SECRET_KEY" "$(q .services.storage.environment.RUSTFS_SECRET_KEY)" "dummy-openseo/STORAGE_SECRET_KEY"
check "runtime AWS_SECRET_ACCESS_KEY" "$(q .services.runtime.environment.AWS_SECRET_ACCESS_KEY)" "dummy-openseo/STORAGE_SECRET_KEY"
check "init AWS_ACCESS_KEY_ID" "$(q .services.init.environment.AWS_ACCESS_KEY_ID)" "dummy-openseo/STORAGE_ACCESS_KEY"
check "init AUTH_MODE" "$(q .services.init.environment.AUTH_MODE)" "local_noauth"
check "init BETTER_AUTH_URL" "$(q .services.init.environment.BETTER_AUTH_URL)" "https://open-seo.rida.sh"
check "init OPENROUTER_MODEL" "$(q .services.init.environment.OPENROUTER_MODEL)" ""
check "init DATAFORSEO_API_KEY" "$(q .services.init.environment.DATAFORSEO_API_KEY)" "dummy-openseo/DATAFORSEO_API_KEY"
check "init GOOGLE_CLIENT_SECRET" "$(q .services.init.environment.GOOGLE_CLIENT_SECRET)" "dummy-openseo/GOOGLE_CLIENT_SECRET"
check "init CONTEXT_API_KEY" "$(q .services.init.environment.CONTEXT_API_KEY)" "dummy-openseo/CONTEXT_API_KEY"

expect_render() {
  label=$1
  outcome=$2
  if render "$3" "$4" > /dev/null 2> "$scratch/case.err"; then got=renders; else got=aborts; fi
  if [ "$got" = "$outcome" ]; then pass; else fail "$label: expected compose to $outcome, it $got ($(head -1 "$scratch/case.err"))"; fi
}

for key in $secret_keys; do
  grep -v "^$key=" "$scratch/rendered/openseo.env" > "$scratch/missing.env"
  expect_render "secrets without the $key line" aborts "$committed_env" "$scratch/missing.env"
  { grep -v "^$key=" "$scratch/rendered/openseo.env"; echo "$key=''"; } > "$scratch/empty.env"
  case $(expected_op "$key") in
    ":?") expect_render "secrets with $key empty" aborts "$committed_env" "$scratch/empty.env" ;;
    "?") expect_render "secrets with $key empty" renders "$committed_env" "$scratch/empty.env" ;;
    *) fail "$key has no empty policy in $keys" ;;
  esac
done

for key in AUTH_MODE BETTER_AUTH_URL OPENROUTER_MODEL; do
  grep -v "^$key=" "$committed_env" > "$scratch/committed-missing.env"
  expect_render "committed env without the $key line" aborts "$scratch/committed-missing.env" "$scratch/rendered/openseo.env"
done
for key in AUTH_MODE BETTER_AUTH_URL; do
  { grep -v "^$key=" "$committed_env"; echo "$key="; } > "$scratch/committed-empty.env"
  expect_render "committed env with $key empty" aborts "$scratch/committed-empty.env" "$scratch/rendered/openseo.env"
done
: > "$scratch/nothing.env"
expect_render "no rendered secrets file content" aborts "$committed_env" "$scratch/nothing.env"

lint_status=0
sh scripts/compose-lint.sh --env-file homelab.env --env-file "$committed_env" --secret-env openseo.env "$compose_file" > "$scratch/lint.out" 2>&1 || lint_status=$?
check "compose-lint exit ($(tr '\n' ' ' < "$scratch/lint.out"))" "$lint_status" "0"

lint_bare_status=0
sh scripts/compose-lint.sh --env-file homelab.env --env-file "$committed_env" "$compose_file" > /dev/null 2>&1 || lint_bare_status=$?
check "compose-lint without --secret-env flags the secret interpolations" "$lint_bare_status" "1"

diff_status=0
sh scripts/compose-diff.sh openseo openseo/compose.yaml "$compose_file" > "$scratch/diff.out" 2> "$scratch/diff.err" || diff_status=$?
if [ "$diff_status" -le 1 ]; then pass; else fail "compose-diff exit $diff_status: $(cat "$scratch/diff.err")"; fi
check "services only in the old file" "$(grep -c 'does not define' "$scratch/diff.out" || true)" "0"
grep -E '^[+-]' "$scratch/diff.out" | grep -vE '^(\+\+\+|---) ' > "$scratch/changes" || true
grep -vE '"image": |"env_file"|<repo>|<secrets>' "$scratch/changes" > "$scratch/disallowed" || true
if [ -s "$scratch/disallowed" ]; then
  fail "compose-diff shows changes outside pin, env_file and path classes:
$(cat "$scratch/disallowed")"
else
  pass
fi

if gitleaks dir --redact --no-banner --exit-code 1 apps/openseo > "$scratch/gitleaks.out" 2>&1; then
  pass
else
  fail "gitleaks found leaks in apps/openseo"
fi

finish
