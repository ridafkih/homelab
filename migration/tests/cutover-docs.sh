#!/usr/bin/env bash
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root" || exit 2

cutover=docs/cutover.md
hardware=docs/hardware.md
failure_log=$(mktemp -t cutover-docs.XXXXXX)
trap 'rm -f "$failure_log"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" | tee -a "$failure_log"
}

failures() {
  grep -c '^FAIL' "$failure_log"
}

for doc in "$cutover" "$hardware"; do
  [ -f "$doc" ] || fail "$doc is missing"
done
if [ "$(failures)" -gt 0 ]; then
  printf '%s check(s) failed\n' "$(failures)"
  exit 1
fi

nvme=$(grep -oE '/dev/disk/by-id/nvme-[A-Za-z0-9_.-]+' hosts/homelab/disks.nix | head -n1)
disk1_uuid=$(sed -nE 's|.*"/mnt/disk1" = dataDisk "([0-9a-f-]+)".*|\1|p' modules/storage.nix)
disk2_uuid=$(sed -nE 's|.*"/mnt/disk2" = dataDisk "([0-9a-f-]+)".*|\1|p' modules/storage.nix)
key_file=$(sed -nE 's|.*keyFile = "([^"]+)".*|\1|p' modules/secrets.nix)
edge_prefixes=$(awk '/cloudflareTunnelEdge = \{/,/^    \};/' modules/options.nix | grep -oE '"[0-9a-f.:]+/[0-9]+"' | tr -d '"')
compose_projects=$(awk '/^  projects = \{/,/^  \};/' modules/docker-apps.nix | sed -nE 's/^    ([a-z0-9]+) = \{.*/\1/p')
restic_jobs=$(awk '/services\.restic\.backups = \{/,/^  \};/' modules/backup.nix | sed -nE 's/^    ([a-z0-9]+) = job .*/\1/p')
restic_timer_jobs=$(awk '/services\.restic\.backups = \{/,/^  \};/' modules/backup.nix | awk '/^    [a-z0-9]+ = job/ { job = $1 } /timerConfig = \{/ { print job }')

for value in nvme disk1_uuid disk2_uuid key_file edge_prefixes compose_projects restic_jobs restic_timer_jobs; do
  [ -n "${!value}" ] || fail "could not read $value from the Nix config; this test's parser needs updating"
done

defined_units=$(
  {
    for project in $compose_projects; do printf '%s-compose\n' "$project"; done
    for job in $restic_jobs; do printf 'restic-backups-%s\n' "$job"; done
    grep -rhoE 'systemd\.services\.[A-Za-z0-9_-]+' modules hosts | sed 's/^systemd\.services\.//'
    printf '%s\n' docker docker.socket tailscaled sshd systemd-networkd nvidia-persistenced \
      systemd-timesyncd network-online.target multi-user.target mnt-disk1.mount mnt-disk2.mount data.mount
  } | sort -u
)
defined_timers=$(
  {
    for job in $restic_timer_jobs; do printf 'restic-backups-%s\n' "$job"; done
    grep -rhoE 'systemd\.timers\.[A-Za-z0-9_-]+' modules hosts | sed 's/^systemd\.timers\.//'
  } | sort -u
)

slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9 -]//g; s/ /-/g'
}

section() {
  awk -v want="$2" '
    /^## / { heading = substr($0, 4); gsub(/[^A-Za-z0-9 -]/, "", heading); gsub(/ /, "-", heading); current = tolower(heading); next }
    current == want { print }
  ' "$1"
}

code_lines() {
  awk '
    /^## / { heading = substr($0, 4); gsub(/[^A-Za-z0-9 -]/, "", heading); gsub(/ /, "-", heading); current = tolower(heading); next }
    /^[[:space:]]*(```|~~~)/ { fenced = !fenced; next }
    fenced { print current "\t" $0 }
  ' "$1"
}

require() {
  local doc=$1 pattern=$2 why=$3
  grep -qE -- "$pattern" "$doc" || fail "$doc: $why"
}

require_in_section() {
  local name=$1 pattern=$2 why=$3
  grep -qiE -- "$pattern" <<<"$(section "$cutover" "$name")" || fail "$cutover #$name: $why"
}

anchors="pre-flight windows-vm state install post-boot rollback optional-firewall cleanup"
headings=$(grep -E '^## ' "$cutover" | while IFS= read -r line; do slug "${line#\#\# }"; printf '\n'; done)
previous=0
for anchor in $anchors; do
  position=$(printf '%s\n' "$headings" | grep -nxF -- "$anchor" | head -n1 | cut -d: -f1)
  if [ -z "$position" ]; then
    fail "$cutover has no '## ' heading whose anchor is #$anchor"
  elif [ "$position" -le "$previous" ]; then
    fail "$cutover: #$anchor is out of order (expected $anchors)"
  else
    previous=$position
  fi
done

require "$cutover" 'nixos-install .*--flake github:ridafkih/homelab/nixos#homelab' 'installs with nixos-install --flake github:ridafkih/homelab/nixos#homelab'
grep -qE 'nixosConfigurations\.homelab\b' flake.nix || fail 'flake.nix does not define nixosConfigurations.homelab'
grep -oE -- '--flake [^ `]*#[A-Za-z0-9_-]+' "$cutover" | sed -E 's/.*#//' | sort -u | while IFS= read -r attr; do
  grep -qE "nixosConfigurations\.$attr\b" flake.nix || printf 'FAIL: %s names flake attr #%s, which flake.nix does not define\n' "$cutover" "$attr"
done | tee -a "$failure_log"

for doc in "$cutover" "$hardware"; do
  grep -oE '`[^`]+`' "$doc" | tr -d '`' | sed -E 's|^\./||; s|[#:].*$||; s|[),.;]+$||' \
    | grep -E '^((apps|modules|hosts|docs|migration|secrets|scripts|tests)/[A-Za-z0-9_./-]*|flake\.nix|flake\.lock|compose\.yaml|homelab\.env|\.sops\.yaml|\.gitleaks\.toml|README\.md)$' \
    | grep -v '[<>*]' | sort -u | while IFS= read -r path; do
      [ -e "$path" ] || printf 'FAIL: %s references repo path %s, which does not exist in the branch\n' "$doc" "$path"
    done
done | tee -a "$failure_log"

check_unit() {
  local unit=$1 where=$2 name
  case "$unit" in
    *.timer)
      name=${unit%.timer}
      printf '%s\n' "$defined_timers" | grep -qxF -- "$name" || fail "$where names $unit, which the branch does not define"
      ;;
    *)
      name=${unit%.service}
      printf '%s\n' "$defined_units" | grep -qxF -- "$name" || fail "$where names unit $unit, which the branch does not define"
      ;;
  esac
}

nixos_sections="post-boot optional-firewall cleanup"
while IFS=$'\t' read -r where line; do
  case " $nixos_sections " in *" $where "*) ;; *) continue ;; esac
  for unit in $(printf '%s\n' "$line" | grep -oE '(systemctl|journalctl)( +-{1,2}[A-Za-z-]+)*( +[a-z-]+)?( +[A-Za-z0-9@_.-]+)+' \
    | awk '{ for (i = 2; i <= NF; i++) { if ($i ~ /^-/ || $i == "-u") continue; if ($1 == "systemctl" && !seen_verb) { seen_verb = 1; continue } print $i } seen_verb = 0 }'); do
    check_unit "$unit" "$cutover #$where code"
  done
done < <(code_lines "$cutover")

for where in $nixos_sections; do
  for unit in $(section "$cutover" "$where" | grep -oE '`[a-z0-9@_-]+\.(service|timer)`' | tr -d '`' | sort -u); do
    check_unit "$unit" "$cutover #$where"
  done
done
for unit in $(grep -oE '`[a-z0-9]+-compose(\.service)?`|`restic-backups-[a-z0-9]+(\.service|\.timer)?`|`egress-policy(\.service)?`' "$cutover" | tr -d '`' | sort -u); do
  check_unit "$unit" "$cutover"
done

for unit in $(for project in $compose_projects; do printf '%s-compose ' "$project"; done) $(for job in $restic_jobs; do printf 'restic-backups-%s ' "$job"; done) egress-policy tailscaled; do
  grep -qF -- "$unit" "$cutover" || fail "$cutover never names $unit"
done

for doc in "$cutover" "$hardware"; do
  require "$doc" "$nvme" "does not name the NVMe by-id path from hosts/homelab/disks.nix ($nvme)"
done
require "$hardware" "$disk1_uuid" 'disk inventory lacks the disk1 UUID from modules/storage.nix'
require "$hardware" "$disk2_uuid" 'disk inventory lacks the disk2 UUID from modules/storage.nix'
require "$cutover" "by-uuid/$disk2_uuid" 'never mounts disk2 by its UUID'
for doc in "$cutover" "$hardware"; do
  for uuid in $(grep -oE '\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b' "$doc" | sort -u); do
    [ "$uuid" = "$disk1_uuid" ] || [ "$uuid" = "$disk2_uuid" ] || fail "$doc names UUID $uuid, which is not a data disk in modules/storage.nix"
  done
  for id in $(grep -oE '/dev/disk/by-id/[A-Za-z0-9_.-]+' "$doc" | sed -E 's/-part[0-9]+$//' | sort -u); do
    [ "$id" = "$nvme" ] || fail "$doc names $id; the only by-id path the branch declares is $nvme"
  done
done

require "$cutover" "/mnt$key_file" "restores the host age key to /mnt$key_file before first boot"
require "$cutover" '/mnt/disk2/migration/rollback' 'keeps rollback images under /mnt/disk2/migration/rollback'
require "$cutover" '[Pp]oint of no return' 'states the point of no return'
grep -iE 'point of no return' "$cutover" | grep -qiE 'first (nixos )?boot' || fail "$cutover: the point of no return is not tied to the first NixOS boot"
require "$cutover" 'cloudflareTunnelEdge' 'pre-flight does not diff the published edge prefixes against homelab.cloudflareTunnelEdge'
for cidr in $(grep -oE '\b(198\.41\.[0-9]+\.[0-9]+/[0-9]+|2606:4700:[0-9a-f:]*/[0-9]+)' "$cutover" "$hardware" | cut -d: -f2- | sort -u); do
  printf '%s\n' "$edge_prefixes" | grep -qxF -- "$cidr" || fail "Cloudflare prefix $cidr in the docs is not in homelab.cloudflareTunnelEdge"
done

carve_out=$(awk 'BEGIN { RS = "" } tolower($0) ~ /cloudflare/ && tolower($0) ~ /mullvad/ && tolower($0) ~ /exception/ && tolower($0) ~ /tunnel/ { print; exit }' "$cutover")
if [ -z "$carve_out" ]; then
  fail "$cutover has no paragraph that explains the Cloudflare tunnel edge exception to whole-box Mullvad"
else
  printf '%s' "$carve_out" | grep -qiE 'fail(s)? closed|kill.?switch|blocked|unreachable' \
    || fail "$cutover: the Cloudflare carve-out paragraph does not say everything else fails closed"
  printf '%s' "$carve_out" | grep -qiE 'refuse|reject|blocks? (every|all) mullvad|won.t (accept|connect)|doesn.t (accept|connect)|does not (accept|connect)' \
    || fail "$cutover: the Cloudflare carve-out paragraph does not say why (the edge refuses Mullvad relays)"
fi

require_in_section pre-flight 'restic.*restore|restore.*restic' 'restores a restic snapshot into a scratch dir'
require_in_section pre-flight '(^|[^a-z])diff ' 'diffs the restored snapshot'
require_in_section pre-flight 'docker save' 'docker saves the pinned images'
require_in_section pre-flight '/mnt/disk2/migration' 'writes to /mnt/disk2/migration'
require_in_section pre-flight 'efibootmgr -v' 'captures efibootmgr -v'
require_in_section pre-flight 'am\.i\.mullvad\.net|mullvad' 're-runs the Mullvad probe'
require_in_section pre-flight 'cloudflare' 're-runs the Cloudflare edge probe'
require_in_section pre-flight '1password' 'checks the host age key in 1Password'
require_in_section pre-flight '(^|[^a-z])df ' 'gates on free space with df'
require_in_section windows-vm 'cp --sparse=always' 'copies the VM disk with cp --sparse=always'
require_in_section windows-vm '/data/windows' 'copies the VM disk to /data/windows'
require_in_section windows-vm 'sha256sum|b3sum|sha256' 'checksums both copies'
require_in_section state 'down' 'brings compose down'
require_in_section state 'rsync' 'rsyncs the state'
for item in '/var/lib/docker/volumes' 'metadata\.db' '\.data' '/var/lib/tailscale' 'ssh_host_' 'machine-id' '/mnt/disk2/migration'; do
  require_in_section state "$item" "does not carry $item"
done
require_in_section state 'storage.?driver|docker info' 'checks the Docker storage driver before copying volumes'
require_in_section install 'virtual media' 'boots the ISO over the KVM virtual media'
require_in_section install 'readlink -f' 'gates on readlink -f of the by-id path'
for tool in sfdisk partclone zstd 'dd '; do
  require_in_section install "$tool" "takes the NVMe rollback image with $tool before disko"
done
require_in_section install 'zstd -t' 'verifies the rollback image with zstd -t'
require_in_section install 'disko' 'runs disko'
require_in_section install 'umask 077' 'writes the age key under umask 077'
install_text=$(section "$cutover" install)
rollback_line=$(printf '%s\n' "$install_text" | grep -niE 'partclone' | head -n1 | cut -d: -f1)
disko_line=$(printf '%s\n' "$install_text" | grep -nE '(^|[^a-z])disko( |$)|disko-install|#disko|disko\.' | grep -viE 'before disko|rollback' | head -n1 | cut -d: -f1)
if [ -n "$rollback_line" ] && [ -n "$disko_line" ] && [ "$rollback_line" -gt "$disko_line" ]; then
  fail "$cutover #install: the rollback image comes after disko"
fi
restore_line=$(printf '%s\n' "$install_text" | grep -nF "/mnt$key_file" | head -n1 | cut -d: -f1)
install_line=$(printf '%s\n' "$install_text" | grep -nE 'nixos-install ' | head -n1 | cut -d: -f1)
if [ -n "$restore_line" ] && [ -n "$install_line" ] && [ "$restore_line" -gt "$install_line" ]; then
  fail "$cutover #install: the age key is restored after nixos-install"
fi

post_boot=$(section "$cutover" post-boot)
post_boot_checks=$(printf '%s\n' "$post_boot" | sed -E 's/[a-z0-9]+-compose(\.service)?//g')
previous=0
for marker in 'findmnt|mountpoint' '10\.0\.0\.98' 'am\.i\.mullvad\.net' 'nvidia-smi' 'cdi' 'caddy' 'authentik' 'webfinger' 'seafile' 'adguard' 'openseo' '8006' 'restic-backups-'; do
  position=$(printf '%s\n' "$post_boot_checks" | grep -niE -- "$marker" | head -n1 | cut -d: -f1)
  if [ -z "$position" ]; then
    fail "$cutover #post-boot: no check for $marker"
  elif [ "$position" -lt "$previous" ]; then
    fail "$cutover #post-boot: the $marker check is out of the required order"
  else
    previous=$position
  fi
done
for item in 'systemctl stop tailscaled' 'curl' 'nvenc' 'digest|sha256' 'sonarr|radarr|prowlarr|arr stack' '/data/media' 'snapshots'; do
  grep -qiE -- "$item" <<<"$post_boot" || fail "$cutover #post-boot: missing $item"
done
for job in $restic_jobs; do
  grep -qF -- "restic-backups-$job" <<<"$post_boot" || fail "$cutover #post-boot: no manual run of restic-backups-$job"
done

for item in 'sfdisk' 'partclone' 'efibootmgr' 'migration/rollback' 'boot menu|one-time boot|bootnext'; do
  require_in_section rollback "$item" "rollback does not use $item"
done
grep -qiE 'point of no return|first (nixos )?boot' <<<"$(section "$cutover" rollback)" || fail "$cutover #rollback: no separate notes for before and after the point of no return"
require_in_section optional-firewall 'rida' 'optional firewall is not left as Rida'"'"'s choice'
require_in_section optional-firewall '8006|3389' 'optional firewall does not name the ports it would close'
require_in_section cleanup 'HF_TOKEN' 'cleanup does not delete the stale HF_TOKEN'
require_in_section cleanup '\.before-' 'cleanup does not delete the *.before-* files'
require_in_section cleanup 'hugging ?face' 'cleanup does not hand the Hugging Face revocation to Rida'
grep -iE 'window' "$cutover" | grep -qiE 'rida' || fail "$cutover does not say the window is Rida's to pick"

grep -niE 'kexec' "$cutover" | grep -viE 'never|not|no |don.t|without' | sed "s|^|FAIL: $cutover kexec mention without a prohibition: |" | tee -a "$failure_log"
code_lines "$cutover" | cut -f2 | grep -nE '(^|[^a-z-])kexec( |$)|modprobe -r nvidia' | sed "s|^|FAIL: $cutover runs kexec or its GPU prep: |" | tee -a "$failure_log"
grep -E 'nixos-anywhere +-' "$cutover" | while IFS= read -r line; do
  printf '%s\n' "$line" | grep -qE -- '--build-on remote' || printf 'FAIL: %s nixos-anywhere without --build-on remote: %s\n' "$cutover" "$line"
  printf '%s\n' "$line" | grep -qE -- '--phases +[a-z,]+' || printf 'FAIL: %s nixos-anywhere without explicit --phases (kexec must be excluded): %s\n' "$cutover" "$line"
  printf '%s\n' "$line" | grep -qE -- '--phases +[a-z,]*kexec' && printf 'FAIL: %s nixos-anywhere phases include kexec: %s\n' "$cutover" "$line"
done | tee -a "$failure_log"

write_targets() {
  code_lines "$cutover" | awk -F'\t' -v nvme="$nvme" -v d1="$disk1_uuid" -v d2="$disk2_uuid" '
    function subst(text,   name) {
      for (name in vars) {
        gsub("\\$\\{" name "\\}", vars[name], text)
        gsub("\\$" name "([^A-Za-z0-9_]|$)", vars[name] "&", text)
        gsub(vars[name] "\\$" name, vars[name], text)
      }
      return text
    }
    function emit(target) {
      gsub(/["'\'']/, "", target)
      if (target != "" && target !~ /^-/) print section "\t" target
    }
    {
      section = $1
      line = $2
      sub(/#.*/, "", line)
      if (match(line, /^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]*$/)) {
        assignment = line
        sub(/^[[:space:]]*(export[[:space:]]+)?/, "", assignment)
        sub(/[[:space:]]+$/, "", assignment)
        name = assignment; sub(/=.*/, "", name)
        value = assignment; sub(/^[^=]*=/, "", value); gsub(/["'\'']/, "", value)
        vars[name] = subst(value)
        next
      }
      line = subst(line)
      if (match(line, /mount[^|;&]*by-uuid\/[0-9a-f-]+[^[:space:]]*[[:space:]]+[^[:space:]]+/)) {
        mount = substr(line, RSTART, RLENGTH)
        n = split(mount, words, /[[:space:]]+/)
        point = words[n]; gsub(/["'\'']/, "", point)
        if (mount ~ d1) print "alias\t" point "\t/mnt/disk1"
        if (mount ~ d2) print "alias\t" point "\t/mnt/disk2"
      }
      gsub(/[0-9&]>&?[0-9]/, "", line)
      gsub(/[0-9&]>[[:space:]]*\/dev\/null/, "", line)
      count = split(line, commands, /&&|\|\||;|\|/)
      for (c = 1; c <= count; c++) {
        command = commands[c]
        while (match(command, />>?[[:space:]]*[^[:space:]>]+/)) {
          target = substr(command, RSTART, RLENGTH); sub(/^>>?[[:space:]]*/, "", target); emit(target)
          command = substr(command, 1, RSTART - 1) " " substr(command, RSTART + RLENGTH)
        }
        n = split(command, words, /[[:space:]]+/)
        first = 1
        while (first <= n && (words[first] == "" || words[first] == "sudo" || words[first] == "env" || words[first] ~ /^[A-Z_]+=/ || words[first] == "nice" || words[first] == "ionice" || words[first] ~ /^-n|^-c/)) first++
        tool = words[first]
        if (tool == "dd") { for (i = first + 1; i <= n; i++) if (words[i] ~ /^of=/) { target = words[i]; sub(/^of=/, "", target); emit(target) } }
        else if (tool ~ /^(rsync|cp|mv|install|ln)$/) { for (i = n; i > first; i--) if (words[i] != "" && words[i] !~ /^-/) { emit(words[i]); break } }
        else if (tool ~ /^(rm|mkdir|touch|truncate|tee|mkfs.*|wipefs|sgdisk|parted|blkdiscard|mkswap)$/) { for (i = first + 1; i <= n; i++) emit(words[i]) }
        else if (tool == "sfdisk" && command !~ /(^|[[:space:]])(-d|--dump|-l|--list)([[:space:]]|$)/) { for (i = first + 1; i <= n; i++) if (words[i] ~ /^\//) emit(words[i]) }
        else if (tool ~ /^(partclone|zstd|docker)/) { for (i = first + 1; i < n; i++) if (words[i] ~ /^(-o|-O|--output)$/) emit(words[i + 1]) }
        else if (tool == "restic") { for (i = first + 1; i < n; i++) if (words[i] == "--target") emit(words[i + 1]) }
      }
    }
  '
}

targets=$(write_targets)
aliases=$(printf '%s\n' "$targets" | awk -F'\t' '$1 == "alias" { print length($2) "\t" $2 "\t" $3 }' | sort -rn | cut -f2-)
data_rule_sections="windows-vm state install rollback"
while IFS=$'\t' read -r where target; do
  [ "$where" = alias ] && continue
  [ -n "$target" ] || continue
  normalized=$target
  while IFS=$'\t' read -r point disk; do
    [ -n "$point" ] || continue
    case "$normalized" in "$point" | "$point"/*) normalized="$disk${normalized#"$point"}"; break ;; esac
  done <<<"$aliases"
  case "$normalized" in
    /dev/null | /dev/stdout | /dev/stderr) ;;
    /dev/*)
      case "$normalized" in
        "$nvme" | "$nvme"-part*) ;;
        *) fail "$cutover #$where writes to device $target; only $nvme may be written" ;;
      esac
      ;;
  esac
  case " $data_rule_sections " in *" $where "*) ;; *) continue ;; esac
  case "$normalized" in
    /mnt/disk2/migration | /mnt/disk2/migration/* | /data/windows | /data/windows/*) ;;
    /mnt/disk1 | /mnt/disk1/* | /mnt/disk2 | /mnt/disk2/* | /data | /data/*)
      fail "$cutover #$where writes to $target on a data disk outside /mnt/disk2/migration and /data/windows"
      ;;
  esac
done <<<"$targets"

code_lines "$cutover" | cut -f2 | grep -E '(^|[^a-z])disko( |$)|disko-install|nix-community/disko' | while IFS= read -r line; do
  printf '%s\n' "$line" | grep -qE -- "$nvme|#homelab|hosts/homelab/disks\.nix" \
    || printf 'FAIL: %s runs disko without the by-id path or the homelab flake: %s\n' "$cutover" "$line"
done | tee -a "$failure_log"
section "$cutover" rollback | grep -nE '(^|[^a-z])(disko|mkfs[a-z.0-9]*|wipefs|sgdisk|nixos-install)( |$)' \
  | sed "s|^|FAIL: $cutover #rollback reformats or reinstalls: |" | tee -a "$failure_log"

secret_path='key\.txt|\.env([^.a-z]|$)|\.pass([^a-z]|$)|RESTIC_PASSWORD|/run/secrets|secrets/homelab\.yaml|\.before-'
for doc in "$cutover" "$hardware"; do
  code_lines "$doc" | cut -f2 | while IFS= read -r line; do
    stripped=$(printf '%s\n' "$line" | sed -E 's/[0-9&]>&?[0-9]//g; s/[0-9&]> *\/dev\/null//g')
    if printf '%s\n' "$line" | grep -qE 'sops +(-d|--decrypt|decrypt|exec-env|exec-file)|age +(-d|--decrypt)'; then
      printf 'FAIL: %s decrypts a secret: %s\n' "$doc" "$line"
    fi
    if printf '%s\n' "$line" | grep -qE 'op +read'; then
      printf '%s\n' "$stripped" | grep -qE '>|--out-file' || printf 'FAIL: %s op read without a redirect: %s\n' "$doc" "$line"
      printf '%s\n' "$line" | grep -qE 'op +read[^|]*\| *(cat|tee|less|more|head|tail|xxd|od)' && printf 'FAIL: %s op read piped to a printer: %s\n' "$doc" "$line"
    fi
    if printf '%s\n' "$line" | grep -qE "(echo|printf)[^|>]*\\$\\{?[A-Z_]*(TOKEN|PASSWORD|PASS|SECRET|KEY)"; then
      printf 'FAIL: %s echoes a secret variable: %s\n' "$doc" "$line"
    fi
    if printf '%s\n' "$line" | grep -qE "$secret_path" && printf '%s\n' "$line" | grep -qE '(^|[^a-z-])(cat|grep|head|tail|less|more|sed|awk|strings|xxd|od|bat|diff|cut)( |$)'; then
      printf '%s\n' "$stripped" | grep -qE 'grep +(-[A-Za-z]*[qcl]|--quiet|--count|--files-with-matches)|test +-[sfe]|\[ +-[sfe]|>|sed +-i|\| *ssh|cmp -s' \
        || printf 'FAIL: %s may print a secret: %s\n' "$doc" "$line"
    fi
  done
done | tee -a "$failure_log"

for doc in "$cutover" "$hardware"; do
  grep -nE 'ts\.net|/Users/|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|op://[^<$]|\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b|\b[0-9a-f]{32}\b|\b[a-z0-9]{26}\b|\b[0-9]{16}\b|\b2[0-9a-f]{3}:[0-9a-f]{1,4}:' "$doc" \
    | grep -vE '2606:4700:' | sed "s|^|FAIL: $doc exposes an identifier on the never-public list (0015): |"
done | tee -a "$failure_log"

if command -v gitleaks >/dev/null 2>&1; then
  for doc in "$cutover" "$hardware"; do
    gitleaks dir --no-banner --redact "$doc" >/dev/null 2>&1 || fail "gitleaks flagged $doc"
  done
else
  fail 'gitleaks is not installed'
fi

for item in 'TDAS' 'chipset' '10G' 'UAS' '-71' 'quirk' 'GL\.iNet' '[~]/grafana' 'Samba' 'Time Machine' '\bsda\b' 'nightly.?reboot' '/mnt/disk2/backup/restic' '/mnt/disk1/backup/restic' 'mergerfs'; do
  require "$hardware" "$item" "does not cover $item"
done
grep -iE 'quirk' "$hardware" | grep -qiE 'no |not|without|never' || fail "$hardware does not say there is no usb-storage quirk"
grep -iE 'not carried over|intentionally' "$hardware" >/dev/null || fail "$hardware has no not-carried-over list"

if [ "$(failures)" -gt 0 ]; then
  printf '%s check(s) failed\n' "$(failures)"
  exit 1
fi
printf 'ok: docs/cutover.md and docs/hardware.md\n'
