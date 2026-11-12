#!/bin/sh
set -u

expected_pin=ghcr.io/caddybuilds/caddy-cloudflare:latest@sha256:9c398a17f826530b99e0a68e63ba85f341ddbadc9c2f23668a1aa8f58ce33fb8

usage() {
  printf 'usage: %s <ssh command to the build host...>\n' "$0" >&2
  printf 'example: %s ssh <build-host>\n' "$0" >&2
  exit 2
}

[ "$#" -ge 1 ] || usage

for tool in docker-compose jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "compose-edge-caddy: missing tool: $tool" >&2; exit 2; }
done

root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd -P)
caddyfile="$root/apps/caddy/Caddyfile"

failures=0

fail() {
  failures=$((failures + 1))
  printf 'fail: %s\n' "$1"
}

pin=$(DOCKER_HOST=unix:///nonexistent docker-compose -f "$root/apps/caddy/compose.yaml" config --no-interpolate --no-consistency --no-path-resolution --format json 2>/dev/null | jq -r '.services.caddy.image // empty')
[ "$pin" = "$expected_pin" ] || fail "apps/caddy/compose.yaml pins caddy to '$pin', expected $expected_pin"
[ -f "$caddyfile" ] || fail "apps/caddy/Caddyfile is missing"

if [ "$failures" -gt 0 ]; then
  printf '%s failed\n' "$failures"
  exit 1
fi

dummy_token=$(printf '%040d' 0)

remote="set -eu
work=\$(mktemp -d)
trap 'rm -rf \"\$work\"' EXIT
cat > \"\$work/Caddyfile\"
docker run --rm --pull never --network none \
  -e DOMAIN=example.test -e HOST_MACHINE_HOSTNAME=host.test -e CLOUDFLARE_API_TOKEN=$dummy_token \
  -v \"\$work/Caddyfile:/etc/caddy/Caddyfile:ro\" \
  $expected_pin caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile"

validate() {
  "$@" "$remote"
}

if validate "$@" < "$caddyfile" > /tmp/compose-edge-caddy.$$ 2>&1; then
  :
else
  fail "caddy validate rejects apps/caddy/Caddyfile"
  sed 's/^/  | /' /tmp/compose-edge-caddy.$$ | tail -20
fi

if { cat "$caddyfile"; printf '\nunclosed.example.test {\n'; } | validate "$@" > /tmp/compose-edge-caddy.$$ 2>&1; then
  fail "negative control: caddy validate accepted a Caddyfile with an unclosed block"
fi
rm -f /tmp/compose-edge-caddy.$$

[ "$failures" -eq 0 ] && echo "caddy validate ok on $pin"
[ "$failures" -eq 0 ]
