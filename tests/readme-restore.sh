#!/usr/bin/env bash
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root" || exit 2

readme=README.md
restore=docs/restore.md
failure_log=$(mktemp -t readme-restore.XXXXXX)
trap 'rm -f "$failure_log"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" | tee -a "$failure_log"
}

failures() {
  grep -c '^FAIL' "$failure_log"
}

finish() {
  if [ "$(failures)" -gt 0 ]; then
    printf '%s check(s) failed\n' "$(failures)"
    exit 1
  fi
}

for doc in "$readme" "$restore"; do
  [ -f "$doc" ] || fail "$doc is missing"
done
finish

dump_dir=$(sed -nE 's|^  dumpDir = "([^"]+)";|\1|p' modules/backup.nix)
restic_jobs=$(awk '/services\.restic\.backups = \{/,/^  \};/' modules/backup.nix | sed -nE 's/^    ([a-z0-9]+) = job .*/\1/p')
job_pairs=$(awk '/services\.restic\.backups = \{/,/^  \};/' modules/backup.nix | sed -nE 's/^    ([a-z0-9]+) = job "([^"]+)" "([^"]+)".*/\1 \2 \3/p')
compose_projects=$(awk '/^  projects = \{/,/^  \};/' modules/docker-apps.nix | sed -nE 's/^    ([a-z0-9]+) = \{.*/\1/p')
key_file=$(sed -nE 's|.*keyFile = "([^"]+)".*|\1|p' modules/secrets.nix)
containers=$(sed -nE 's/^ +container_name: *"?([A-Za-z0-9_.-]+)"?.*/\1/p' apps/*/compose.yaml | sort -u)
apps=$(for dir in apps/*/; do basename "$dir"; done)

for value in dump_dir restic_jobs job_pairs compose_projects key_file containers apps; do
  [ -n "${!value}" ] || fail "could not read $value from the branch; this test's parser needs updating"
done
finish

line_count=$(wc -l <"$readme" | tr -d ' ')
[ "$line_count" -le 150 ] || fail "$readme is $line_count lines; keep it short (about 120)"

links() {
  grep -oE '\]\([^)]+\)' "$1" | sed -E 's/^\]\(//; s/\)$//; s/[[:space:]].*$//' | grep -vE '^(https?:|mailto:|#)' | sed -E 's/#.*$//'
}

for doc in "$readme" "$restore"; do
  base=$(dirname "$doc")
  links "$doc" | sort -u | while IFS= read -r target; do
    [ -n "$target" ] || continue
    [ -e "$base/$target" ] || printf 'FAIL: %s links to %s, which does not exist\n' "$doc" "$target"
  done
  grep -oE '`[^`]+`' "$doc" | tr -d '`' | sed -E 's|^\./||; s|[#:].*$||; s|[),.;]+$||' \
    | grep -E '^((apps|modules|hosts|docs|migration|secrets|scripts|tests)(/[A-Za-z0-9_./-]*)?|flake\.nix|flake\.lock|compose\.yaml|homelab\.env|\.sops\.yaml|\.gitleaks\.toml|README\.md|LICENSE)$' \
    | grep -v '[<>*]' | sort -u | while IFS= read -r path; do
      [ -e "$path" ] || printf 'FAIL: %s names repo path %s, which does not exist in the branch\n' "$doc" "$path"
    done
done | tee -a "$failure_log"

grep -qE '\]\(\./docs/cutover\.md(#[a-z0-9-]+)?\)' "$readme" || fail "$readme does not link ./docs/cutover.md"
grep -qE '\]\(\./docs/restore\.md(#[a-z0-9-]+)?\)' "$readme" || fail "$readme does not link ./docs/restore.md"
grep -qE '\]\(\./docs/hardware\.md(#[a-z0-9-]+)?\)' "$readme" || fail "$readme does not link ./docs/hardware.md"

grep -niE '3090|--profile|COMPOSE_PROFILES|makefile|make (up|down)|\.env\.example|cp \.env|~/|/home/' "$readme" \
  | sed "s|^|FAIL: $readme names something retired or a personal path: |" | tee -a "$failure_log"
grep -niE 'still (runs|on) arch|runs arch|not yet (migrated|on nixos)|migration (status|is pending)' "$readme" \
  | sed "s|^|FAIL: $readme carries a migration status line that goes stale: |" | tee -a "$failure_log"

dropped=$(grep -niE 'pi-?hole|ollama|keeper' "$readme")
dropped_lines=$(printf '%s' "$dropped" | grep -c . || true)
if [ "$dropped_lines" -ne 1 ]; then
  fail "$readme must name Pi-hole, Ollama and Keeper.sh on exactly one not-carried-over line (found $dropped_lines lines)"
else
  for name in 'pi-?hole' 'ollama' 'keeper\.sh'; do
    grep -qiE -- "$name" <<<"$dropped" || fail "$readme's not-carried-over line does not name $name"
  done
fi
for doc in "$readme" "$restore"; do
  grep -niE 'keeper([^.]|\.[^s]|$)' "$doc" | sed "s|^|FAIL: $doc spells Keeper.sh as Keeper: |"
  grep -niE 'pi-?hole|ollama' "$doc" | grep -viE 'keeper\.sh' | sed "s|^|FAIL: $doc names a dropped service outside the not-carried-over line: |"
done | tee -a "$failure_log"

require() {
  local doc=$1 pattern=$2 why=$3
  grep -qiE -- "$pattern" "$doc" || fail "$doc: $why"
}

require_line() {
  local doc=$1 first=$2 second=$3 why=$4
  grep -iE -- "$first" "$doc" | grep -qiE -- "$second" || fail "$doc: $why"
}

require "$readme" 'nixos-rebuild switch .*--flake \.#homelab' 'no deploy command nixos-rebuild switch --flake .#homelab'
grep -qE 'nixosConfigurations\.homelab\b' flake.nix || fail 'flake.nix does not define nixosConfigurations.homelab'
for project in $compose_projects; do
  require "$readme" "$project-compose" "does not name the $project-compose unit"
done
grep -oE '`[a-z0-9]+-compose(\.service)?`' "$readme" "$restore" | cut -d: -f2- | tr -d '`' | sed 's/\.service$//' | sort -u | while IFS= read -r unit; do
  printf '%s\n' $compose_projects | grep -qxF -- "${unit%-compose}" || printf 'FAIL: docs name unit %s, which modules/docker-apps.nix does not define\n' "$unit"
done | tee -a "$failure_log"

for entry in flake.nix hosts/homelab modules apps secrets docs; do
  grep -qE "(^|[^A-Za-z0-9_/.-])$entry/?([^A-Za-z0-9_-]|$)" "$readme" || fail "$readme layout does not list $entry"
done
for app in $apps; do
  pattern=$(printf '%s' "$app" | sed -E 's/-/[- ]?/g')
  grep -qiE -- "$pattern" "$readme" || fail "$readme does not say what runs in apps/$app"
done
require "$readme" '4080' 'does not name the RTX 4080 Super'

require "$readme" 'sops' 'does not explain sops secrets'
require "$readme" '1password' 'does not say the age keys live in 1Password'
require_line "$readme" 'plaintext|plain text' 'never|not|no ' 'does not say secrets are never in git as plaintext'

require "$readme" 'on-disk' 'does not say backups are on-disk'
require_line "$readme" 'off-?site|cloud|remote' 'no |not|none|never' 'does not say there is no off-site copy for now'
require "$readme" 'restic' 'does not name restic'
require_line "$readme" 'media' 'not backed up|never backed up|excluded|isn.t backed up|skip' 'does not say media is not backed up'
require_line "$readme" 'windows' 'not backed up|never backed up|excluded|isn.t backed up|skip' 'does not say the Windows disk is excluded'
require "$readme" 'cross' 'does not explain the two crossed repos'

require "$readme" 'mullvad' 'does not cover whole-box Mullvad egress'
require_line "$readme" 'mullvad' 'whole box|entire box|all (outbound )?traffic|everything' 'does not say the whole box goes out through Mullvad'
carve_out=$(awk 'BEGIN { RS = "" } tolower($0) ~ /cloudflare/ && tolower($0) ~ /mullvad/ && tolower($0) ~ /(exception|except|only flow|carve)/ { print; exit }' "$readme")
if [ -z "$carve_out" ]; then
  fail "$readme has no paragraph stating the one Cloudflare tunnel exception to Mullvad"
else
  grep -qiE 'refuse|reject|block|won.t|doesn.t|does not' <<<"$carve_out" || fail "$readme: the Cloudflare exception does not say why"
  grep -qiE 'fail(s)? closed|kill.?switch' "$readme" || fail "$readme does not say egress fails closed"
fi

for pair in $(printf '%s\n' "$job_pairs" | tr ' ' ','); do
  job=${pair%%,*}
  rest=${pair#*,}
  half=${rest%%,*}
  repo=${rest#*,}
  require "$restore" "$repo" "does not name repo $repo"
  require "$restore" "restic-$job" "does not use the restic-$job wrapper"
  require_line "$restore" "$repo" "$half" "never pairs repo $repo with the Seafile half it holds ($half)"
  for other in $(printf '%s\n' "$job_pairs" | awk '{ print $2 }'); do
    [ "$other" = "$half" ] && continue
    grep -iF -- "$repo" "$restore" | grep -qF -- "$other" && fail "$restore pairs repo $repo with $other; it holds $half"
  done
done
grep -oE 'restic-[a-z0-9]+' "$restore" | sort -u | while IFS= read -r wrapper; do
  name=${wrapper#restic-}
  case "$name" in backups) continue ;; esac
  printf '%s\n' $restic_jobs | grep -qxF -- "$name" || printf 'FAIL: %s uses %s, which modules/backup.nix does not define\n' "$restore" "$wrapper"
done | tee -a "$failure_log"
grep -oE 'restic-backups-[a-z0-9]+' "$restore" "$readme" | cut -d: -f2- | sort -u | while IFS= read -r unit; do
  printf '%s\n' $restic_jobs | grep -qxF -- "${unit#restic-backups-}" || printf 'FAIL: docs name %s, which modules/backup.nix does not define\n' "$unit"
done | tee -a "$failure_log"

require "$restore" 'snapshots' 'does not list snapshots'
require "$restore" 'restic[^`]* check|-disk[0-9]+ check' 'does not run restic check'
require "$restore" 'restore [^`]*--target' 'does not restore with --target'
require "$restore" '--include' 'does not show a single-path restore with --include'
require "$restore" 'restic/RESTIC_PASSWORD' 'does not say where the restic password comes from'
require "$restore" "$key_file" "does not name the host age key path $key_file"
require "$restore" '1password' 'does not say how to recover the age key from 1Password'
require "$restore" 'seaf-fsck' 'does not run seaf-fsck after a Seafile restore'
require_line "$restore" 'same night|same snapshot|same run' 'mix|corrupt|never|must' 'does not warn against mixing nights'
require "$restore" "$dump_dir" "does not name the dump directory $dump_dir"
require "$restore" 'authentik-postgresql\.sql' 'does not restore the Authentik Postgres dump'
require "$restore" 'seafile-db\.sql' 'does not restore the Seafile MariaDB dump'
require "$restore" 'psql' 'does not load the Postgres dump with psql'
require "$restore" 'mariadb' 'does not load the MariaDB dump with mariadb'
require "$restore" 'manifest\.json' 'does not verify OpenSEO tarballs against manifest.json'
require "$restore" 'sha256' 'does not check the OpenSEO sha256'
require "$restore" '/var/lib/tailscale' 'does not restore /var/lib/tailscale'
require "$restore" '/var/lib/docker/volumes' 'does not restore Docker volumes'
require_line "$restore" 'media' 'not backed up|never backed up|can.t be restored|cannot be restored|no backup' 'does not say media cannot be restored'

grep -oE '(docker( compose)? (exec|stop|start|restart|logs)( +-[A-Za-z]+)*|docker exec -i) +[a-z0-9_.-]+' "$restore" \
  | awk '{ print $NF }' | sort -u | while IFS= read -r name; do
    printf '%s\n' "$containers" | grep -qxF -- "$name" && continue
    printf 'FAIL: %s names container %s, which no apps/*/compose.yaml defines\n' "$restore" "$name"
  done | tee -a "$failure_log"
grep -oE 'systemctl +(start|stop|restart|status)( +[A-Za-z0-9@_.-]+)+' "$restore" | awk '{ for (i = 3; i <= NF; i++) print $i }' \
  | sed -E 's/\.(service|timer)$//' | sort -u | while IFS= read -r unit; do
    case "$unit" in
      docker | tailscaled) continue ;;
      restic-backups-*) printf '%s\n' $restic_jobs | grep -qxF -- "${unit#restic-backups-}" && continue ;;
      *-compose) printf '%s\n' $compose_projects | grep -qxF -- "${unit%-compose}" && continue ;;
    esac
    printf 'FAIL: %s stops or starts unit %s, which the branch does not define\n' "$restore" "$unit"
  done | tee -a "$failure_log"

code_lines() {
  awk '/^[[:space:]]*(```|~~~)/ { fenced = !fenced; next } fenced { print }' "$1"
}

for doc in "$readme" "$restore"; do
  code_lines "$doc" | while IFS= read -r line; do
    if printf '%s\n' "$line" | grep -qE 'sops +(-d|--decrypt|decrypt)'; then
      printf '%s\n' "$line" | grep -qE -- '>|--output' || printf 'FAIL: %s decrypts a secret to the terminal: %s\n' "$doc" "$line"
    fi
    if printf '%s\n' "$line" | grep -qE 'op +read'; then
      printf '%s\n' "$line" | grep -qE -- '>|--out-file|\| *ssh|\| *sudo +(install|tee|sh)' || printf 'FAIL: %s op read without a redirect: %s\n' "$doc" "$line"
    fi
    if printf '%s\n' "$line" | grep -qE 'RESTIC_PASSWORD|key\.txt|/run/secrets' && printf '%s\n' "$line" | grep -qE '(^|[^a-z-])(cat|head|tail|less|more|xxd|od|strings|bat)( |$)'; then
      printf '%s\n' "$line" | grep -qE '>|\| *(ssh|sudo +(install|tee|sh))' || printf 'FAIL: %s may print a secret: %s\n' "$doc" "$line"
    fi
    if printf '%s\n' "$line" | grep -qE "(echo|printf)[^|>]*\\$\\{?[A-Z_]*(TOKEN|PASSWORD|PASS|SECRET|KEY)"; then
      printf 'FAIL: %s echoes a secret variable: %s\n' "$doc" "$line"
    fi
    if printf '%s\n' "$line" | grep -qE '(RESTIC_PASSWORD|MYSQL_ROOT_PASSWORD|PGPASSWORD)=[^$[:space:]"]'; then
      printf 'FAIL: %s sets a literal password: %s\n' "$doc" "$line"
    fi
  done
done | tee -a "$failure_log"

for doc in "$readme" "$restore"; do
  grep -nE 'ts\.net|/Users/|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|op://[^<$]|\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b|\b[0-9a-f]{32}\b|\b[a-z0-9]{26}\b|\b[0-9]{16}\b|\b2[0-9a-f]{3}:[0-9a-f]{1,4}:' "$doc" \
    | grep -vE '2606:4700:' | sed "s|^|FAIL: $doc exposes an identifier on the never-public list (0013): |"
done | tee -a "$failure_log"

if command -v gitleaks >/dev/null 2>&1; then
  for doc in "$readme" "$restore"; do
    gitleaks dir --no-banner --redact "$doc" >/dev/null 2>&1 || fail "gitleaks flagged $doc"
  done
else
  fail 'gitleaks is not installed'
fi

finish
printf 'ok: README.md and docs/restore.md\n'
