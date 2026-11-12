#!/bin/sh
set -eu

usage() {
  echo "usage: exposure.sh [--denylist FILE] [DIR]" >&2
  echo "       exposure.sh [--denylist FILE] --history REV..." >&2
  exit 2
}

denylist=
history=
while [ "$#" -ge 1 ]; do
  case $1 in
    --denylist)
      [ "$#" -ge 2 ] || usage
      denylist=$2
      shift 2
      [ -f "$denylist" ] || usage
      ;;
    --history)
      history=1
      shift
      break
      ;;
    *) break ;;
  esac
done
if [ -n "$history" ]; then
  [ "$#" -ge 1 ] || usage
else
  [ "$#" -le 1 ] || usage
  if [ "$#" -eq 1 ]; then
    tree=$1
  else
    tree=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
  fi
  [ -d "$tree" ] || usage
fi

for tool in grep find sed; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool"; exit 2; }
done

tab=$(printf '\t')
dot='\.'
users=Users
identity=IdentityAgent

vendored="apps/observability/config/signoz/clickhouse-config.xml"

denylist_patterns() {
  grep -vE '^[[:space:]]*($|[#])' "$1" || true
}

if [ -n "$denylist" ] && [ -z "$(denylist_patterns "$denylist")" ]; then
  echo "exposure: the denylist $denylist holds no patterns" >&2
  exit 2
fi

patterns() {
  printf '%s\t%s\n' \
    email "[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(${dot}[A-Za-z0-9-]+)*${dot}[A-Za-z]{2,}" \
    "tailnet domain" "${dot}ts${dot}net([^A-Za-z]|\$)" \
    "local user path" "/${users}/" \
    "private key path" "[~]/${dot}ssh/id_|${identity}=none" \
    "MAC address" '(^|[^0-9A-Fa-f:])([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}([^0-9A-Fa-f:]|$)'
  [ -z "$1" ] || denylist_patterns "$1" | sed "s/^/denylist${tab}/"
}

allowed() {
  grep -vE '^[^:]+:[0-9]+:.*-ed25519@openssh\.com' || true
}

files() {
  (cd "$1" && find . -name .git -prune -o -type f -print | sed 's#^\./##' | LC_ALL=C sort) | while read -r path; do
    case " $vendored " in
      *" $path "*) continue ;;
    esac
    printf '%s\n' "$path"
  done
}

tree_hits() {
  patterns "$2" | while IFS="$tab" read -r label pattern; do
    files "$1" | while read -r path; do
      grep -nIE -- "$pattern" "$1/$path" 2>/dev/null | sed "s#^#$path:#; s#\$# [$label]#"
    done
  done | allowed
}

shell_files() {
  files "$1" | grep -E '\.(sh|nix)$' || true
}

fallback_hits() {
  shell_files "$1" | while read -r path; do
    grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*:[-=]|\$\{[0-9@*#]:[-=]' "$1/$path" 2>/dev/null | sed "s#^#$path:#; s#\$# [shell fallback]#"
  done
}

scan() {
  {
    tree_hits "$1" "$2"
    fallback_hits "$1"
  } | LC_ALL=C sort -u
}

noreply="[A-Za-z0-9._%+-]+@users${dot}noreply${dot}github${dot}com"

line_hits() {
  patterns "$2" | while IFS="$tab" read -r label pattern; do
    sed -E "s/$noreply//g" "$1" | grep -nIE -- "$pattern" | sed "s#^#$3:#; s#\$# [$label]#"
  done | allowed
}

history_lines() {
  git log --format=%B "$@" > "$work/messages"
  set -- "$@" --
  for path in $vendored; do
    set -- "$@" ":(exclude)$path"
  done
  git log -p --unified=0 --format= --no-ext-diff --no-textconv "$@" | grep -E '^[+]' | grep -vE '^[+][+][+] ' | sed 's/^[+]//' > "$work/added" || true
}

control=$(mktemp -d -t exposure-control.XXXXXX)
work=$control/work
trap 'rm -rf "$control"' EXIT INT TERM
mkdir -p "$control/docs" "$control/scripts" "$work"
at=@
tailnet=ts
key=id_ed25519
mac=aa:bb:cc
{
  printf '%s\n' "reach me at someone${at}example.org"
  printf '%s\n' "host.tail1234.${tailnet}.net"
  printf '%s\n' "/${users}/someone/project"
  printf '%s\n' "built by planted-tool-name"
  printf '%s\n' "ssh -i ~/.ssh/${key} host"
  printf '%s\n' "link ${mac}:dd:ee:ff up"
} > "$control/docs/leaky.md"
printf '%s\n' 'x=$''{TMPDIR:-/tmp}' > "$control/scripts/fallback.sh"
printf '%s\n' "sk-ssh-ed25519${at}openssh.com AAAA" 'sha 45:A8:83:F3:49:AE:DF:D5:F3:A6' > "$control/docs/fine.md"
printf '%s\n' '# planted' 'planted-tool-name' > "$control/denylist"
printf '%s\n' "Co-Authored-By: someone <1+someone${at}users.noreply.github.com>" > "$control/trailer"
cat "$control/docs/leaky.md" "$control/trailer" > "$control/message"

expected="denylist
email
local user path
MAC address
private key path
shell fallback
tailnet domain"
found=$(scan "$control" "$control/denylist" | sed -n 's/.* \[\(.*\)\]$/\1/p' | LC_ALL=C sort -u)
if [ "$found" != "$(printf '%s\n' "$expected" | LC_ALL=C sort -u)" ]; then
  echo "exposure: the scanner missed a planted leak or flagged a safe line"
  printf 'found:\n%s\n' "$found"
  exit 1
fi
if scan "$control" "$control/denylist" | grep -q '^docs/fine\.md:'; then
  echo "exposure: the scanner flags docs/fine.md, which holds only safe lines"
  exit 1
fi
if scan "$control" "" | grep -q '\[denylist\]$'; then
  echo "exposure: the scanner applies a denylist it was not given"
  exit 1
fi
lines_expected=$(printf '%s\n' "$expected" | grep -v 'shell fallback' | LC_ALL=C sort -u)
lines_found=$(line_hits "$control/message" "$control/denylist" message | sed -n 's/.* \[\(.*\)\]$/\1/p' | LC_ALL=C sort -u)
if [ "$lines_found" != "$lines_expected" ]; then
  echo "exposure: the history scan missed a planted leak"
  printf 'found:\n%s\n' "$lines_found"
  exit 1
fi
if [ -n "$(line_hits "$control/trailer" "" message)" ]; then
  echo "exposure: the history scan flags a GitHub noreply co-author trailer"
  exit 1
fi

if [ -n "$history" ]; then
  history_lines "$@"
  leaks=$( { line_hits "$work/messages" "$denylist" message; line_hits "$work/added" "$denylist" added; } | LC_ALL=C sort -u)
  if [ -n "$leaks" ]; then
    echo "exposure: these commit messages or added lines should not be in a public repo:"
    printf '%s\n' "$leaks"
    exit 1
  fi
  echo "ok: no private details in the messages or added lines of $(git rev-list --count "$@") commits"
  exit 0
fi

leaks=$(scan "$tree" "$denylist")
if [ -n "$leaks" ]; then
  echo "exposure: these lines should not be in a public repo:"
  printf '%s\n' "$leaks"
  exit 1
fi
echo "ok: no private details in $(files "$tree" | wc -l | tr -d ' ') files"
