#!/bin/sh
set -eu

usage() {
  echo "usage: compose-lint.sh [--env-file FILE]... [--secret-env TEMPLATE]... FILE..." >&2
  exit 2
}

die() {
  echo "compose-lint: $1" >&2
  exit 2
}

for tool in docker-compose jq; do
  command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
keys="$root/secrets/keys.tsv"
[ -f "$keys" ] || die "missing key table $keys"

scratch=$(mktemp -d -t compose-lint.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

allowed="$scratch/allowed.tsv"
printf 'HOMELAB_DATA_DIR\t\nHOMELAB_SECRETS_DIR\t\n' > "$allowed"

env_pairs() {
  sed -n "s/^\([A-Za-z_][A-Za-z0-9_]*\)=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}$/\1	\2/p" "$1"
}

template_keys() {
  awk -F '\t' -v t="$1" '$1 == t && $2 != "-" { print $2 "\t" }' "$keys"
}

while [ $# -gt 0 ]; do
  case $1 in
    --env-file)
      [ $# -ge 2 ] || usage
      [ -f "$2" ] || die "env file not found: $2"
      env_pairs "$2" >> "$allowed"
      shift 2
      ;;
    --secret-env)
      [ $# -ge 2 ] || usage
      awk -F '\t' -v t="$2" '$1 == t { found = 1 } END { exit !found }' "$keys" || die "template $2 is not in $keys"
      template_keys "$2" >> "$allowed"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || usage

absolute() {
  printf '%s/%s\n' "$(CDPATH='' cd -- "$(dirname -- "$1")" 2>/dev/null && pwd -P || printf '%s' "$(dirname -- "$1")")" "$(basename -- "$1")"
}

include_list() {
  awk '/^include:/ { on = 1; next } /^[^ ]/ { on = 0 } on && /^ *- / { sub(/^ *- */, ""); print }' "$1"
}

declared_networks() {
  awk '
    /^networks:/ { on = 1; indent = ""; next }
    /^[^ #]/ { on = 0 }
    on && /^ +[^ #-]/ {
      match($0, /^ +/)
      lead = substr($0, 1, RLENGTH)
      if (indent == "") indent = lead
      if (lead == indent) { key = substr($0, RLENGTH + 1); sub(/:.*/, "", key); print key }
    }
  ' "$1"
}

included="$scratch/included"
: > "$included"
if [ -f "$root/compose.yaml" ]; then
  include_list "$root/compose.yaml" | while read -r entry; do absolute "$root/$entry"; done > "$included"
fi

allowed_json=$(jq -Rn '[inputs | split("\t") | {key: .[0], value: (.[1] // "")}] | from_entries' < "$allowed")
secrets_json=$(awk -F '\t' '{ if ($2 != "-") print $2; n = split($3, p, "/"); print p[n] }' "$keys" | jq -Rn '[inputs | {key: ., value: true}] | from_entries')
templates_json=$(awk -F '\t' '$1 != "-" { print $1 }' "$keys" | jq -Rn '[inputs | {key: ., value: true}] | from_entries')

rules='
def service_of($p): if $p[0] == "services" and ($p | length) > 1 then $p[1] else "-" end;
def report($svc; $rule; $detail): "\($file): \($svc): \($rule): \($detail)";
def interpolations: gsub("\\$\\$"; "") | [scan("\\$\\{[^}]*\\}?|\\$[A-Za-z_][A-Za-z0-9_]*")];
def parse: if startswith("${") then (capture("^\\$\\{(?<name>[A-Za-z_][A-Za-z0-9_]*)(?<op>[^}]*)\\}$") // {name: null, op: .}) else {name: .[1:], op: null} end;
def required_op: . != null and (startswith(":?") or startswith("?"));
def escapes: test("(^|/)\\.\\.(/|$)");
def absolute_var($s): ($s | capture("^\\$\\{(?<name>[A-Za-z_][A-Za-z0-9_]*):?\\?[^}]*\\}") // null) as $m
  | $m != null and (if $m.name == "HOMELAB_DATA_DIR" then true else (($allowed[$m.name] // "") | startswith("/")) end);
def volume_ok($s; $named):
  if $s | escapes then false
  elif $s | startswith("/") then true
  elif $s | test("^\\$\\{HOMELAB_DATA_DIR:\\?\\}(/|$)") then true
  elif $s | startswith("${") then absolute_var($s)
  elif $s | startswith("./") then ($s | test("^\\./\\.data(/|$)") | not)
  elif $s | test("^[A-Za-z0-9][A-Za-z0-9_.-]*$") then ($named | any(. == $s))
  else false end;
def env_path: if type == "object" then .path else . end;

(.volumes // {} | keys) as $named
| [paths(type == "string") as $p | {svc: service_of($p), value: getpath($p)}]
| map(.svc as $svc | .value | interpolations[] | . as $raw | parse | . + {svc: $svc, raw: $raw})
| (map(
    if .name == null or (.op | required_op | not) then report(.svc; "a-fallback"; "\(.raw) must be ${NAME:?} or ${NAME?}")
    else empty end)
  + map(select(.name != null) | .name as $name |
    if $allowed | has($name) then empty
    elif $secrets | has($name) then report(.svc; "b-secret"; "\(.raw) interpolates the secret key \(.name); read it from an env_file")
    else report(.svc; "b-unlisted"; "\(.raw) interpolates \(.name), which is not in a passed --env-file") end))
| .[]
,
($root.services // {} | to_entries[] | .key as $svc | .value |
  (if .build != null then report($svc; "c-build"; "build is not allowed; pin a published image")
   elif .image == null then report($svc; "c-no-image"; "service has no image")
   elif (.image | test("^[^$@]+:[^@$]+@sha256:[0-9a-f]{64}$") | not) then report($svc; "c-unpinned"; "\(.image) is not pinned as tag@sha256")
   else empty end),
  ((.volumes // [])[] | select(.source != null) | .source as $s |
    if volume_ok($s; $named) then empty
    elif ($s | test("^[A-Za-z0-9][A-Za-z0-9_.-]*$")) then report($svc; "d-undeclared"; "named volume \($s) is not declared in this file")
    else report($svc; "d-bind"; "bind source \($s) must be absolute, ${HOMELAB_DATA_DIR:?}/..., an absolute env value or ./... without .. or .data") end),
  ((.env_file // []) | if type == "array" then .[] else . end | env_path as $e |
    ($e | capture("^\\$\\{HOMELAB_SECRETS_DIR:\\?\\}/(?<t>[^/]+)$") // null) as $m |
    if $m != null and ($templates | has($m.t)) then empty
    else report($svc; "e-env-file"; "env_file \($e) must be ${HOMELAB_SECRETS_DIR:?}/<template> with a template from secrets/keys.tsv") end))
'

violations="$scratch/violations"
: > "$violations"
seen_networks="$scratch/networks"
: > "$seen_networks"
index=0

for file in "$@"; do
  [ -f "$file" ] || die "file not found: $file"
  index=$((index + 1))
  path=$(absolute "$file")

  source_file=$file
  if grep -q '^include:' "$file"; then
    source_file="$scratch/without-include-$index.yaml"
    awk '/^include:/ { skip = 1; next } /^[^ ]/ { skip = 0 } !skip' "$file" > "$source_file"
  fi

  render="$scratch/render-$index.json"
  docker-compose -f "$source_file" config --no-interpolate --no-consistency --no-path-resolution --format json > "$render" 2> "$scratch/render.err" || {
    cat "$scratch/render.err" >&2
    die "cannot render $file"
  }

  jq -r --arg file "$file" --argjson allowed "$allowed_json" --argjson secrets "$secrets_json" --argjson templates "$templates_json" \
    '. as $root | '"$rules" "$render" >> "$violations" || die "cannot apply the rules to $file"

  sets_name=false
  grep -q '^name:' "$file" && sets_name=true
  if grep -qxF "$path" "$included"; then
    [ "$sets_name" = false ] || echo "$file: -: f-name: files in the root include must not set name" >> "$violations"
    if declared_networks "$file" | grep -qx 'homelab-network'; then
      echo "$file: -: f-network: homelab-network is declared only in the root compose.yaml" >> "$violations"
    fi
  elif [ "$sets_name" = false ]; then
    echo "$file: -: f-name: a file outside the root include is its own project and must set name" >> "$violations"
  fi

  for network in $(declared_networks "$file"); do
    previous=$(awk -F '\t' -v n="$network" '$1 == n { print $2; exit }' "$seen_networks")
    if [ -n "$previous" ]; then
      echo "$file: -: f-duplicate-network: $network is already declared in $previous" >> "$violations"
    else
      printf '%s\t%s\n' "$network" "$file" >> "$seen_networks"
    fi
  done
done

[ -s "$violations" ] || exit 0
awk '!seen[$0]++' "$violations"
exit 1
