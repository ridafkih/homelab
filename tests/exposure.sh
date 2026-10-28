#!/bin/sh
set -eu

usage() {
  echo "usage: exposure.sh [--denylist FILE] [DIR]" >&2
  exit 2
}

denylist=
if [ "$#" -ge 1 ] && [ "$1" = --denylist ]; then
  [ "$#" -ge 2 ] || usage
  denylist=$2
  shift 2
  [ -f "$denylist" ] || usage
fi
[ "$#" -le 1 ] || usage
if [ "$#" -eq 1 ]; then
  tree=$1
else
  tree=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
fi
[ -d "$tree" ] || usage

for tool in grep find sed; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool"; exit 2; }
done

dot='\.'
users=Users
identity=IdentityAgent
run='<ru''n>'

vendored="apps/observability/config/signoz/clickhouse-config.xml"

files() {
  (cd "$1" && find . -name .git -prune -o -type f -print | sed 's#^\./##' | LC_ALL=C sort) | while read -r path; do
    case " $vendored " in
      *" $path "*) continue ;;
    esac
    printf '%s\n' "$path"
  done
}

hits() {
  label=$1 pattern=$2 root=$3
  files "$root" | while read -r path; do
    grep -nIE -- "$pattern" "$root/$path" 2>/dev/null | sed "s#^#$path:#; s#\$# [$label]#"
  done
}

email_hits() {
  hits email "[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(${dot}[A-Za-z0-9-]+)*${dot}[A-Za-z]{2,}" "$1" | grep -vE '^[^:]+:[0-9]+:.*-ed25519@openssh\.com' || true
}

denylist_hits() {
  [ -n "$2" ] || return 0
  grep -vE '^[[:space:]]*($|[#])' "$2" | while IFS= read -r pattern; do
    hits denylist "$pattern" "$1"
  done
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
    email_hits "$1"
    hits "tailnet domain" "${dot}ts${dot}net([^A-Za-z]|\$)" "$1"
    hits "local user path" "/${users}/" "$1"
    hits "tooling notes" "[Oo]wner rules? [0-9]|^## Agent context|${run}/|[(]winner [A-Z][)]|CLAUDE${dot}md" "$1"
    denylist_hits "$1" "$2"
    hits "private key path" "[~]/${dot}ssh/id_|${identity}=none" "$1"
    hits "MAC address" '(^|[^0-9A-Fa-f:])([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}([^0-9A-Fa-f:]|$)' "$1"
    fallback_hits "$1"
  } | LC_ALL=C sort -u
}

control=$(mktemp -d -t exposure-control.XXXXXX)
trap 'rm -rf "$control"' EXIT INT TERM
mkdir -p "$control/docs" "$control/scripts"
at=@
tailnet=ts
key=id_ed25519
mac=aa:bb:cc
rule=12
winner=B
period=.
{
  printf '%s\n' "reach me at someone${at}example.org"
  printf '%s\n' "host.tail1234.${tailnet}.net"
  printf '%s\n' "/${users}/someone/project"
  printf '%s\n' "built by planted-tool-name"
  printf '%s\n' "Owner rule ${rule} says so"
  printf '%s\n' "## Agent context"
  printf '%s\n' "notes in ${run}/plan"
  printf '%s\n' "option two (winner ${winner})"
  printf '%s\n' "see CLAUDE${period}md"
  printf '%s\n' "ssh -i ~/.ssh/${key} host"
  printf '%s\n' "link ${mac}:dd:ee:ff up"
} > "$control/docs/leaky.md"
printf '%s\n' 'x=$''{TMPDIR:-/tmp}' > "$control/scripts/fallback.sh"
printf '%s\n' "sk-ssh-ed25519${at}openssh.com AAAA" 'sha 45:A8:83:F3:49:AE:DF:D5:F3:A6' > "$control/docs/fine.md"
printf '%s\n' '# planted' 'planted-tool-name' > "$control/denylist"

expected="denylist
email
local user path
MAC address
private key path
shell fallback
tailnet domain
tooling notes"
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
notes=$(scan "$control" "" | grep -c '\[tooling notes\]$' || true)
if [ "$notes" -ne 5 ]; then
  echo "exposure: the scanner caught $notes of the 5 planted tooling notes"
  exit 1
fi
if scan "$control" "" | grep -q '\[denylist\]$'; then
  echo "exposure: the scanner applies a denylist it was not given"
  exit 1
fi

leaks=$(scan "$tree" "$denylist")
if [ -n "$leaks" ]; then
  echo "exposure: these lines should not be in a public repo:"
  printf '%s\n' "$leaks"
  exit 1
fi
echo "ok: no private details in $(files "$tree" | wc -l | tr -d ' ') files"
