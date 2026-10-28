#!/bin/sh
set -eu

baseline=9af811a

usage() {
  echo "usage: compose-diff.sh <homelab|openseo|windows> <old-path-in-$baseline> <new-file>" >&2
  exit 2
}

die() {
  echo "compose-diff: $1" >&2
  exit 2
}

[ $# -eq 3 ] || usage
project=$1
old_path=$2
new_file=$3

case $project in
  homelab | openseo | windows) ;;
  *) die "unknown project $project" ;;
esac

for tool in docker-compose jq git diff; do
  command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
root_logical=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
keys="$root/secrets/keys.tsv"
[ -f "$keys" ] || die "missing key table $keys"
[ -f "$new_file" ] || die "new file not found: $new_file"
new_file=$(CDPATH='' cd -- "$(dirname -- "$new_file")" && pwd -P)/$(basename -- "$new_file")
git -C "$root" cat-file -e "$baseline^{commit}" 2>/dev/null || die "baseline $baseline is not in $root"

scratch=$(mktemp -d -t compose-diff.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM
scratch_physical=$(CDPATH='' cd -- "$scratch" && pwd -P)

old_root="$scratch/old"
old_file="$old_root/$old_path"
secrets_dir="$scratch/secrets"
mkdir -p "$(dirname -- "$old_file")" "$secrets_dir" "$old_root/.data"
git -C "$root" show "$baseline:$old_path" > "$old_file" 2>/dev/null || die "$old_path is not in $baseline"

include_list() {
  awk '/^include:/ { on = 1; next } /^[^ ]/ { on = 0 } on && /^ *- / { sub(/^ *- */, ""); print }' "$1"
}

if [ "$project" = homelab ]; then
  new_render_file="$root/compose.yaml"
  [ -f "$new_render_file" ] || die "missing $new_render_file"
  include_list "$new_render_file" | while read -r entry; do [ ! -f "$root/$entry" ] || echo "$root/$entry"; done > "$scratch/scanned"
  own_env=""
else
  new_render_file=$new_file
  : > "$scratch/scanned"
  own_env="$(dirname -- "$new_file")/$project.env"
fi

interpolations() {
  while read -r path; do sed 's/\$\$//g' "$path"; done | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*[^}]*\}?|\$[A-Za-z_][A-Za-z0-9_]*' || true
}

needs_value() {
  sed -E -e 's/^\$\{?([A-Za-z_][A-Za-z0-9_]*)(.*)$/\1 \2/' | awk '
    { name = $1; op = substr($0, length(name) + 2) }
    op !~ /^:?-/ { need[name] = 1 }
    { seen[name] = 1 }
    END { for (n in seen) if (need[n]) print n }
  ' | LC_ALL=C sort
}

env_file="$scratch/env"
{
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$root/homelab.env" || true
  if [ -n "$own_env" ] && [ -f "$own_env" ]; then grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$own_env" || true; fi
  awk -F '\t' -v t="$project.env" '{ n = split($3, p, "/"); print p[n] "=dummy-" $3; if ($1 == t && $2 != "-") print $2 "=dummy-" $3 }' "$keys"
  printf '%s\n' "$old_file" "$new_file" "$new_render_file" | cat - "$scratch/scanned" | interpolations | needs_value | sed 's/.*/&=dummy-&/'
} | grep -vE '^HOMELAB_(DATA|SECRETS)_DIR=' | awk -F '=' '!seen[$1]++' > "$env_file"

awk -F '\t' '$1 != "-" && $2 != "-" { print $2 "='"'"'dummy-" $3 "'"'"'" > (dir "/" $1) }' dir="$secrets_dir" "$keys"
cp "$env_file" "$(dirname -- "$old_file")/.env"

compose() {
  env -i PATH="$PATH" HOME="$HOME" \
    HOMELAB_DATA_DIR="$old_root/.data" HOMELAB_SECRETS_DIR="$secrets_dir" \
    docker-compose -p "$project" --env-file "$env_file" "$@"
}

services=$(docker-compose -f "$new_file" config --no-interpolate --no-consistency --no-path-resolution --format json 2> "$scratch/err" | jq -c '.services // {} | keys') || {
  cat "$scratch/err" >&2
  die "cannot read the services of $new_file"
}

compose -f "$old_file" config --format json > "$scratch/old.json" 2> "$scratch/err" || {
  cat "$scratch/err" >&2
  die "cannot render $baseline:$old_path"
}
compose -f "$new_render_file" config --format json > "$scratch/new.json" 2> "$scratch/err" || {
  cat "$scratch/err" >&2
  die "cannot render $new_render_file"
}

select_services='
  (.services // {} | with_entries(select(.key as $k | $names | any(. == $k)))) as $services
  | ([$services[] | .networks // {} | keys[]] | unique) as $networks
  | ([$services[] | .volumes // [] | .[] | select(.type == "volume") | .source] | unique) as $volumes
  | {
      name,
      services: $services,
      networks: (.networks // {} | with_entries(select(.key as $k | $networks | any(. == $k)))),
      volumes: (.volumes // {} | with_entries(select(.key as $k | $volumes | any(. == $k))))
    }
'

squeeze() {
  printf '%s\n' "$1" | sed 's|//*|/|g'
}

prefixes=$(
  for pair in "$scratch_physical/old <repo>" "$scratch/old <repo>" "$scratch_physical/secrets <secrets>" "$scratch/secrets <secrets>" "$root <repo>" "$root_logical <repo>"; do
    printf '%s\n' "$pair"
  done | while read -r from to; do jq -n --arg from "$(squeeze "$from")" --arg to "$to" '{from: $from, to: $to}'; done | jq -s -c .
)

relocate='
  walk(
    if type == "string" and startswith("/") then
      gsub("/+"; "/") as $path
      | reduce $prefixes[] as $p ($path;
          if . == $p.from or startswith($p.from + "/") then $p.to + .[($p.from | length):] else . end)
    else . end)
'

normalise() {
  jq -S --argjson names "$services" --argjson prefixes "$prefixes" "$select_services | $relocate" "$1"
}

normalise "$scratch/old.json" > "$scratch/old.normal.json"
normalise "$scratch/new.json" > "$scratch/new.normal.json"

new_label=${new_file#"$root"/}
status=0
diff -u -L "$baseline:$old_path" -L "$new_label" "$scratch/old.normal.json" "$scratch/new.normal.json" || status=$?
[ "$status" -le 1 ] || die "diff failed"

dropped=$(jq -r --argjson names "$services" '.services // {} | keys[] | select(. as $k | $names | any(. == $k) | not)' "$scratch/old.json")
if [ -n "$dropped" ]; then
  echo
  echo "Services in $baseline:$old_path that $new_label does not define:"
  printf '%s\n' "$dropped" | sed 's/^/  - /'
fi

exit "$status"
