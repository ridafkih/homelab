#!/bin/sh
set -eu

usage() {
  echo "usage: compose-windows.sh [DOCKER_INSPECT_JSON [REPO_DIGESTS_JSON]]" >&2
  exit 2
}

[ $# -le 2 ] || usage
inspect=""
repo_digests=""
[ $# -lt 1 ] || inspect=$1
[ $# -lt 2 ] || repo_digests=$2

for tool in docker-compose jq git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool"; exit 2; }
done

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
file="$repo/apps/windows/compose.yaml"
digest=sha256:3633f055f31aadf76bb650b1ca86897ab45b76ad8eb2cf81e86389ace5eb45ac
image="dockurr/windows:latest@$digest"
image_defaults='{"PATH":"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin","RAM_SIZE":"4G","CPU_CORES":"2","DISK_SIZE":"64G"}'

scratch=$(mktemp -d -t windows-tests.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

export DOCKER_HOST="unix://$scratch/no-docker-daemon.sock"
unset COMPOSE_PROJECT_NAME COMPOSE_FILE COMPOSE_PROFILES COMPOSE_ENV_FILES 2>/dev/null || true

ran=0
failures=0

pass() { ran=$((ran + 1)); }
fail() { ran=$((ran + 1)); failures=$((failures + 1)); echo "FAIL: $1"; }
check() { if [ "$2" = "$3" ]; then pass; else fail "$1: expected [$3], got [$2]"; fi; }

finish() {
  echo "$ran checks, $failures failed"
  [ "$failures" -eq 0 ] && exit 0
  exit 1
}

if [ -f "$file" ]; then pass; else fail "apps/windows/compose.yaml exists"; finish; fi

render="$scratch/render.json"
if (cd "$scratch" && docker-compose -f "$file" config --format json) > "$render" 2> "$scratch/render.err"; then
  pass
else
  fail "docker-compose config renders apps/windows/compose.yaml without -p: $(cat "$scratch/render.err")"
  finish
fi

q() { jq -cS "$1" "$render"; }
w() { jq -cS ".services.windows | $1" "$render"; }

check "project name without -p" "$(q '.name')" '"windows"'
check "default network name" "$(q '.networks | map_values(.name)')" '{"default":"windows_default"}'
check "service keys" "$(q '.services | keys')" '["windows"]'
check "no top-level volumes" "$(q '.volumes // {} | length')" '0'
check "no top-level secrets or configs" "$(q '[.secrets, .configs] | map(. // {} | length) | add')" '0'
check "container_name" "$(w '.container_name')" '"windows11"'
check "image pinned to the running digest" "$(w '.image')" "\"$image\""
check "environment is VERSION only" "$(w '.environment')" '{"VERSION":"11"}'
check "devices" "$(w '[.devices[] | {source, target, permissions}]')" '[{"permissions":"rwm","source":"/dev/kvm","target":"/dev/kvm"},{"permissions":"rwm","source":"/dev/net/tun","target":"/dev/net/tun"}]'
check "cap_add" "$(w '.cap_add')" '["NET_ADMIN"]'
check "cap_drop" "$(w '.cap_drop // []')" '[]'
check "privileged" "$(w '.privileged // false')" 'false'
check "ports" "$(w '[.ports[] | {target, published, protocol, host_ip: (.host_ip // "")}] | sort_by(.target, .protocol)')" '[{"host_ip":"","protocol":"tcp","published":"3389","target":3389},{"host_ip":"","protocol":"udp","published":"3389","target":3389},{"host_ip":"","protocol":"tcp","published":"8006","target":8006}]'
check "restart" "$(w '.restart')" '"always"'
check "stop_grace_period" "$(w '.stop_grace_period')" '"2m0s"'
check "storage is one bind from /data/windows" "$(w '[.volumes[] | {type, source, target, read_only: (.read_only // false)}]')" '[{"read_only":false,"source":"/data/windows","target":"/storage","type":"bind"}]'
check "no env_file" "$(w '.env_file // [] | length')" '0'
check "default network only" "$(w '.networks | keys')" '["default"]'
check "no network_mode" "$(w '.network_mode // ""')" '""'
check "no build" "$(w '.build // null')" 'null'
check "no command or entrypoint override" "$(w '[.command, .entrypoint]')" '[null,null]'

if grep -q '\$' "$file"; then fail "file has no interpolation"; else pass; fi
if grep -q '#' "$file"; then fail "file has no comments"; else pass; fi
if grep -Eq '(^|[^0-9])[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)' "$file"; then fail "file has no IPv4 addresses"; else pass; fi
if grep -Eiq '([0-9a-f]{2}:){5}[0-9a-f]{2}' "$file"; then fail "file has no MAC addresses"; else pass; fi
if grep -Eiq 'ts\.net|tailnet|homelab|/home/' "$file"; then fail "file has no hostnames or home paths"; else pass; fi
if grep -Eiq 'password|token|secret|key=' "$file"; then fail "file has no secrets"; else pass; fi
check "top-level name line" "$(grep -c '^name: windows$' "$file")" '1'

lint_out=$(sh "$repo/scripts/compose-lint.sh" "$file" 2>&1) && lint_status=0 || lint_status=$?
check "compose-lint.sh passes: $lint_out" "$lint_status" '0'

root_includes=$(awk '/^include:/ { on = 1; next } /^[^ ]/ { on = 0 } on && /^ *- / { sub(/^ *- */, ""); print }' "$repo/compose.yaml")
if printf '%s\n' "$root_includes" | grep -q 'windows'; then fail "apps/windows is not in the root include"; else pass; fi

if [ -n "$inspect" ]; then
  [ -f "$inspect" ] || { echo "inspect file not found: $inspect"; exit 2; }
  live() { jq -cS --argjson defaults "$image_defaults" ".[0] | $1" "$inspect"; }
  live_env='[.Config.Env[] | capture("^(?<key>[^=]+)=(?<value>.*)$")] | from_entries'

  check "live container name" "$(live '.Name')" '"/windows11"'
  check "live compose project" "$(live '.Config.Labels["com.docker.compose.project"]')" '"windows"'
  check "live compose service" "$(live '.Config.Labels["com.docker.compose.service"]')" '"windows"'
  check "live network matches" "$(live '.HostConfig.NetworkMode')" "$(q '.networks.default.name')"
  check "devices match live" \
    "$(w '[.devices[] | {host: .source, container: .target, perms: .permissions}] | sort')" \
    "$(live '[.HostConfig.Devices[] | {host: .PathOnHost, container: .PathInContainer, perms: .CgroupPermissions}] | sort')"
  check "caps match live" \
    "$(w '.cap_add | sort')" \
    "$(live '.HostConfig.CapAdd | map(sub("^CAP_"; "")) | sort')"
  check "ports match live" \
    "$(w '[.ports[] | {key: "\(.target)/\(.protocol)", value: [{HostIp: (.host_ip // ""), HostPort: .published}]}] | from_entries')" \
    "$(live '.HostConfig.PortBindings')"
  check "restart matches live" "$(w '.restart')" "$(live '.HostConfig.RestartPolicy.Name')"
  check "stop grace matches live StopTimeout" "$(live '.Config.StopTimeout')" '120'
  check "environment matches live minus image defaults" \
    "$(w '.environment')" \
    "$(live "$live_env"' | with_entries(select(.key as $k | $defaults | has($k) | not))')"
  check "live image defaults unchanged" \
    "$(live "$live_env"' | with_entries(select(.key as $k | $defaults | has($k)))')" \
    "$(printf '%s' "$image_defaults" | jq -cS .)"
  check "storage target matches live, source moves to /data/windows" \
    "$(w '[.volumes[] | {type, target}]')" \
    "$(live '[.Mounts[] | {type: .Type, target: .Destination}]')"
  check "live has exactly one mount" "$(live '.Mounts | length')" '1'

  if [ -n "$repo_digests" ]; then
    [ -f "$repo_digests" ] || { echo "repo digests file not found: $repo_digests"; exit 2; }
    check "image digest matches the running image" \
      "$(jq -c --arg d "$digest" 'map(select(endswith("@" + $d))) | length' "$repo_digests")" '1'
  fi
fi

finish
