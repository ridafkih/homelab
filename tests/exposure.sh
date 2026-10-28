#!/bin/sh
set -eu

usage() {
  echo "usage: exposure.sh [DIR]" >&2
  exit 2
}

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

agent=wo
agent=${agent}rm
dot='\.'

scanners="tests/exposure.sh tests/readme-restore.sh migration/tests/cutover-docs.sh migration/tests/build-host-doc.sh"
vendored="apps/observability/config/signoz/clickhouse-config.xml"

files() {
  (cd "$1" && find . -name .git -prune -o -type f -print | sed 's#^\./##' | LC_ALL=C sort) | while read -r path; do
    case " $scanners $vendored " in
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
    hits "local user path" '/Users/' "$1"
    hits "agent home" "[~]/${agent}(/|\$|[^A-Za-z.-])|${dot}config/${agent}|${dot}${agent}/runs|${agent}-agent-bot|agent/${agent}" "$1"
    hits "agent run notes" 'Owner rules? [0-9]|owner rule [0-9]|CLAUDE\.md|big-ask|\(winner [A-Z]\)|^## Agent context|<run>/' "$1"
    hits "private key path" '[~]/\.ssh/id_|IdentityAgent=none' "$1"
    hits "MAC address" '(^|[^0-9A-Fa-f:])([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}([^0-9A-Fa-f:]|$)' "$1"
    fallback_hits "$1"
  } | LC_ALL=C sort -u
}

control=$(mktemp -d -t exposure-control.XXXXXX)
trap 'rm -rf "$control"' EXIT INT TERM
mkdir -p "$control/docs" "$control/scripts"
{
  printf '%s\n' "reach me at someone@example.org"
  printf '%s\n' "host.tail1234.ts.net"
  printf '%s\n' "/Users/someone/project"
  printf '%s\n' "token in ~/${agent}/apps/cli"
  printf '%s\n' "key in ~/.config/${agent}/.op/token"
  printf '%s\n' "vault agent/${agent}"
  printf '%s\n' "Owner rule 158 says so"
  printf '%s\n' "ssh -i ~/.ssh/id_ed25519 host"
  printf '%s\n' "link aa:bb:cc:dd:ee:ff up"
} > "$control/docs/leaky.md"
printf '%s\n' 'x=$''{TMPDIR:-/tmp}' > "$control/scripts/fallback.sh"
printf '%s\n' 'sk-ssh-ed25519@openssh.com AAAA' 'sha 45:A8:83:F3:49:AE:DF:D5:F3:A6' > "$control/docs/fine.md"

expected="agent home
agent run notes
email
local user path
MAC address
private key path
shell fallback
tailnet domain"
found=$(scan "$control" | sed -n 's/.* \[\(.*\)\]$/\1/p' | LC_ALL=C sort -u)
if [ "$found" != "$(printf '%s\n' "$expected" | LC_ALL=C sort -u)" ]; then
  echo "exposure: the scanner missed a planted leak or flagged a safe line"
  printf 'found:\n%s\n' "$found"
  exit 1
fi
if scan "$control" | grep -q '^docs/fine\.md:'; then
  echo "exposure: the scanner flags docs/fine.md, which holds only safe lines"
  exit 1
fi

leaks=$(scan "$tree")
if [ -n "$leaks" ]; then
  echo "exposure: these lines should not be in a public repo:"
  printf '%s\n' "$leaks"
  exit 1
fi
echo "ok: no private details in $(files "$tree" | wc -l | tr -d ' ') files"
