#!/bin/sh
set -eu

baseline=9af811a
media_services="prowlarr sonarr radarr bazarr qbittorrent qui jellyseerr"
all_services="jellyfin $media_services"

for tool in docker-compose jq git diff; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool"; exit 2; }
done

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
git -C "$repo" cat-file -e "$baseline^{commit}" 2>/dev/null || { echo "baseline $baseline is not in $repo"; exit 2; }
cd "$repo"

scratch=$(mktemp -d "${TMPDIR:-/tmp}/compose-media.XXXXXX")
trap 'rm -rf "$scratch"' EXIT INT TERM
scratch=$(CDPATH='' cd -- "$scratch" && pwd -P)
export DOCKER_HOST="unix://$scratch/no-docker-daemon.sock"

ran=0
failures=0
pass() { ran=$((ran + 1)); }
fail() { ran=$((ran + 1)); failures=$((failures + 1)); echo "FAIL: $1"; }
check() { if [ "$2" = "$3" ]; then pass; else fail "$1: expected [$3], got [$2]"; fi; }

pin() {
  case $1 in
    jellyfin) echo "jellyfin/jellyfin:latest@sha256:fea863d0cd9ec445985d9c75fc6ed64e38a1d2766cf0c250a33d553f4fc1b771" ;;
    prowlarr) echo "lscr.io/linuxserver/prowlarr:latest@sha256:b3b00047ed20f6ce2b16780145cb6a0acb51c9e28ea6aa6f5dcd33c7034f1797" ;;
    sonarr) echo "linuxserver/sonarr:latest@sha256:48e36b608b461273b9dae857725cd0561a127f2c694b687318f6d0c5ce63e5c9" ;;
    radarr) echo "linuxserver/radarr:latest@sha256:084b3b2ab1d0ef930660727259546a241f2bdf67c9ed085d54bf1486a6887c9b" ;;
    bazarr) echo "lscr.io/linuxserver/bazarr:latest@sha256:946dc8c5bb5331418eac60050cf40a63cb8f66ac039841dda493870e3559799c" ;;
    qbittorrent) echo "lscr.io/linuxserver/qbittorrent:latest@sha256:75ecbb1c89ab7b0a21c4bde40b4820e4f1649d2d56d83b91913422155e8d2a5f" ;;
    qui) echo "ghcr.io/autobrr/qui:main@sha256:eebb8c93a3654ce2ecc7edcd4ace9d96d4c2f3bba1df9bab13543cee6eefcaea" ;;
    jellyseerr) echo "ghcr.io/seerr-team/seerr:latest@sha256:d8fab675b55ad293ded98fd71efcfd46054cbad9746534ae1cc4794a88c0b3be" ;;
  esac
}

data_dir="$scratch/old/.data"
secrets_dir="$scratch/secrets"
mkdir -p "$data_dir" "$secrets_dir"
awk -F '\t' '$1 != "-" && $2 != "-" { print $2 "='"'"'dummy'"'"'" >> (dir "/" $1) }' dir="$secrets_dir" secrets/keys.tsv

grep -vE '^HOMELAB_(DATA|SECRETS)_DIR=' homelab.env > "$scratch/env"
printf 'HOMELAB_SECRETS_DIR=%s\n' "$secrets_dir" >> "$scratch/env"
cp "$scratch/env" "$scratch/env-without-data-dir"
printf 'HOMELAB_DATA_DIR=%s\n' "$data_dir" >> "$scratch/env"

media_root="$scratch/root.yaml"
{
  printf 'name: homelab\n\ninclude:\n  - %s/apps/jellyfin/compose.yaml\n  - %s/apps/media/compose.yaml\n\n' "$repo" "$repo"
  sed -n '/^networks:/,$p' compose.yaml
} > "$media_root"

render() {
  env_file=$1
  shift
  env -i PATH="$PATH" HOME="$HOME" DOCKER_HOST="$DOCKER_HOST" docker-compose --env-file "$env_file" "$@" config --format json
}

render "$scratch/env" -f "$media_root" > "$scratch/new.json" 2> "$scratch/new.err" || { fail "render apps/jellyfin + apps/media through an include root: $(cat "$scratch/new.err")"; echo '{}' > "$scratch/new.json"; }
render "$scratch/env" -f "$media_root" -f apps/jellyfin/compose.nogpu.yaml > "$scratch/nogpu.json" 2> "$scratch/nogpu.err" || { fail "render with apps/jellyfin/compose.nogpu.yaml: $(cat "$scratch/nogpu.err")"; echo '{}' > "$scratch/nogpu.json"; }
render "$scratch/env" -f compose.yaml > "$scratch/root.json" 2> "$scratch/root.err" || { fail "render the root compose.yaml: $(cat "$scratch/root.err")"; echo '{}' > "$scratch/root.json"; }

git show "$baseline:compose.yaml" > "$scratch/old/compose.yaml"
: > "$scratch/old/.env"
env -i PATH="$PATH" HOME="$HOME" DOCKER_HOST="$DOCKER_HOST" docker-compose -p homelab -f "$scratch/old/compose.yaml" config --format json > "$scratch/old.json" 2> "$scratch/old.err" || { echo "cannot render $baseline:compose.yaml: $(cat "$scratch/old.err")"; exit 2; }

for service in $all_services; do
  check "$service is defined" "$(jq -r --arg s "$service" '.services | has($s)' "$scratch/new.json")" true
  check "$service is in the root project" "$(jq -r --arg s "$service" '.services | has($s)' "$scratch/root.json")" true
  check "$service image is the live pin" "$(jq -r --arg s "$service" '.services[$s].image // "missing"' "$scratch/new.json")" "$(pin "$service")"
done

check "apps/jellyfin defines only jellyfin" "$(docker-compose -f apps/jellyfin/compose.yaml config --no-interpolate --no-consistency --no-path-resolution --format json 2>/dev/null | jq -c '.services | keys')" '["jellyfin"]'
check "apps/media defines the seven media services in order" "$(sed -n 's/^  \([a-z][a-z-]*\):$/\1/p' apps/media/compose.yaml | tr '\n' ' ')" "$media_services "

comparable='
  def strip_gpu: del(.runtime, .devices) | .environment |= (if . == null then . else with_entries(select(.key | startswith("NVIDIA_") | not)) end);
  .services[$s] // {} | del(.image) | strip_gpu
'
for service in $all_services; do
  old=$(jq -S --arg s "$service" "$comparable" "$scratch/old.json")
  new=$(jq -S --arg s "$service" "$comparable" "$scratch/new.json")
  if [ "$(jq -r --arg s "$service" '.services | has($s)' "$scratch/new.json")" = true ] && [ "$old" = "$new" ]; then
    pass
  else
    fail "$service differs from $baseline beyond the pin and GPU change: $(printf '%s\n' "$old" > "$scratch/a"; printf '%s\n' "$new" > "$scratch/b"; diff "$scratch/a" "$scratch/b" | head -20 | tr '\n' ' ')"
  fi
done

check "jellyfin gets the GPU through CDI" "$(jq -S -c '.services.jellyfin.devices // null' "$scratch/new.json")" '[{"permissions":"rwm","source":"nvidia.com/gpu=all","target":"nvidia.com/gpu=all"}]'
check "jellyfin has no runtime" "$(jq -c '.services.jellyfin | has("runtime")' "$scratch/new.json")" false
check "jellyfin has no NVIDIA_ env" "$(jq -c '[.services.jellyfin.environment // {} | keys[] | select(startswith("NVIDIA_"))]' "$scratch/new.json")" '[]'
check "jellyfin keeps PUID/PGID" "$(jq -c '.services.jellyfin.environment // null' "$scratch/new.json")" '{"PGID":"1000","PUID":"1000"}'

check "nogpu render keeps jellyfin" "$(jq -r '.services | has("jellyfin")' "$scratch/nogpu.json")" true
check "nogpu render has no devices on jellyfin" "$(jq -c '.services.jellyfin.devices // [] | length' "$scratch/nogpu.json")" 0
check "nogpu override changes nothing but jellyfin devices" "$(jq -S -c 'del(.services.jellyfin.devices)' "$scratch/nogpu.json")" "$(jq -S -c 'del(.services.jellyfin.devices)' "$scratch/new.json")"
if grep -qE '^ +devices: +!reset +\[\]' apps/jellyfin/compose.nogpu.yaml 2>/dev/null; then pass; else fail "compose.nogpu.yaml resets jellyfin devices with !reset []"; fi
check "compose.nogpu.yaml holds only the devices reset" "$(grep -vE '^[[:space:]]*$' apps/jellyfin/compose.nogpu.yaml 2>/dev/null | sed 's/[[:space:]]*$//' | tr '\n' '|')" 'services:|  jellyfin:|    devices: !reset []|'

check "qui has no restart policy" "$(jq -c '.services.qui | has("restart")' "$scratch/new.json")" false
for service in prowlarr bazarr; do
  check "$service mounts the homelab CA bundle read-only" "$(jq -c --arg s "$service" '[.services[$s].volumes // [] | .[] | select(.source == "/etc/homelab-ca/certs" and .target == "/etc/ssl/certs" and .read_only == true)] | length' "$scratch/new.json")" 1
done
check "every /data/media bind is unchanged" "$(jq -S -c '[.services // {} | to_entries[] | .value.volumes // [] | .[] | select(.source | startswith("/data/media"))] | sort_by(.source, .target)' "$scratch/new.json")" "$(jq -S -c --argjson names "$(printf '%s\n' $all_services | jq -R . | jq -s -c .)" '[.services // {} | to_entries[] | select(.key as $k | $names | index($k)) | .value.volumes // [] | .[] | select(.source | startswith("/data/media"))] | sort_by(.source, .target)' "$scratch/old.json")"

for file in apps/jellyfin/compose.yaml apps/media/compose.yaml; do
  raw=$(docker-compose -f "$file" config --no-interpolate --no-consistency --no-path-resolution --format json 2>/dev/null || echo '{}')
  check "$file binds only absolute or HOMELAB_DATA_DIR sources" "$(printf '%s\n' "$raw" | jq -c '[.services // {} | .[] | .volumes // [] | .[] | select(.type == "bind") | .source | select((startswith("/") or startswith("${HOMELAB_DATA_DIR:?}/")) | not)]')" '[]'
  check "$file declares no networks" "$(printf '%s\n' "$raw" | jq -c '.networks // {} | keys')" '[]'
  check "$file sets no project name" "$(grep -c '^name:' "$file" || true)" 0
done

if render "$scratch/env-without-data-dir" -f "$media_root" > /dev/null 2> "$scratch/unset.err"; then
  fail "rendering without HOMELAB_DATA_DIR must fail"
else
  if grep -q HOMELAB_DATA_DIR "$scratch/unset.err"; then pass; else fail "rendering without HOMELAB_DATA_DIR fails on something else: $(cat "$scratch/unset.err")"; fi
fi

hits=$(grep -rnE 'runtime: *nvidia|NVIDIA_VISIBLE_DEVICES|NVIDIA_DRIVER_CAPABILITIES' apps/ || true)
check "no legacy NVIDIA runtime or env under apps/" "$hits" ""

lint_status=0
sh scripts/compose-lint.sh --env-file homelab.env apps/jellyfin/compose.yaml apps/media/compose.yaml > "$scratch/lint.out" 2>&1 || lint_status=$?
check "compose-lint passes: $(cat "$scratch/lint.out")" "$lint_status" 0

changed_lines() {
  sed '/^$/,$d' "$1" | grep -E '^[-+]' | grep -vE '^(---|\+\+\+) '
}

diff_status=0
sh migration/compose-diff.sh homelab compose.yaml apps/media/compose.yaml > "$scratch/media.diff" 2>&1 || diff_status=$?
check "compose-diff media exits 1" "$diff_status" 1
check "compose-diff media changes exactly seven image lines each way" "$(changed_lines "$scratch/media.diff" | grep -cE '^[-+] *"image": ' || true)" 14
check "compose-diff media changes nothing but images" "$(changed_lines "$scratch/media.diff" | grep -vE '^[-+] *"image": ' || true)" ""

diff_status=0
sh migration/compose-diff.sh homelab compose.yaml apps/jellyfin/compose.yaml > "$scratch/jellyfin.diff" 2>&1 || diff_status=$?
check "compose-diff jellyfin exits 1" "$diff_status" 1
check "compose-diff jellyfin swaps the image pin" "$(changed_lines "$scratch/jellyfin.diff" | grep -cE '^[-+] *"image": ' || true)" 2
check "compose-diff jellyfin drops runtime nvidia" "$(changed_lines "$scratch/jellyfin.diff" | grep -cE '^- *"runtime": "nvidia"' || true)" 1
check "compose-diff jellyfin drops the NVIDIA env" "$(changed_lines "$scratch/jellyfin.diff" | grep -cE '^- *"NVIDIA_(VISIBLE_DEVICES|DRIVER_CAPABILITIES)": "all"' || true)" 2
check "compose-diff jellyfin adds the CDI device" "$(changed_lines "$scratch/jellyfin.diff" | grep -cE '^\+ *"(source|target)": "nvidia.com/gpu=all"' || true)" 2
check "compose-diff jellyfin changes nothing else" "$(changed_lines "$scratch/jellyfin.diff" | grep -vE '^[-+] *("image"|"runtime"|"NVIDIA_[A-Z_]+"|"devices"|"source": "nvidia.com/gpu=all"|"target": "nvidia.com/gpu=all"|"permissions": "rwm"|\{|\}|\]|\[)' || true)" ""

echo "$ran checks, $failures failed"
[ "$failures" -eq 0 ]
