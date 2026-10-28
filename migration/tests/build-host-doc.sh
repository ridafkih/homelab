#!/bin/sh
set -u

root=$(cd "$(dirname "$0")/../.." && pwd)
doc="$root/migration/build-host.md"
failures=0

fail() {
  printf 'fail: %s\n' "$1"
  failures=$((failures + 1))
}

require_fixed() {
  grep -qF -- "$1" "$doc" || fail "migration/build-host.md does not mention: $1"
}

if [ ! -f "$doc" ]; then
  printf 'fail: migration/build-host.md is missing\n'
  exit 1
fi

for text in \
  'Nice=19' \
  'IOSchedulingClass=idle' \
  'CPUSchedulingPolicy=batch' \
  'MemoryHigh=16G' \
  'MemoryMax=24G' \
  '50-build-host.conf' \
  'max-jobs = 2' \
  'cores = 4' \
  'system-features = kvm nixos-test big-parallel benchmark' \
  'experimental-features = nix-command flakes' \
  'min-free = 53687091200' \
  'max-free = 107374182400' \
  '--prefer-upstream-nix' \
  '--extra-conf' \
  '~/homelab-nixos-build' \
  'repo.git' \
  'git init --bare' \
  'nice -n19 ionice -c3' \
  'systemd-run --user --scope' \
  'memorySize' \
  'nix store gc' \
  '/nix/nix-installer uninstall' \
  '<build-host>' \
  'nix-daemon' \
  'docker' \
  'tailscaled'
do
  require_fixed "$text"
done

grep -iE 'restart' "$doc" | grep -qiE 'never|only' \
  || fail 'migration/build-host.md does not state the never-restart rule'
grep -iE 'restart' "$doc" | grep -q 'nix-daemon' \
  || fail 'the restart rule does not name nix-daemon as the only unit that may restart'
grep -iE '~/homelab([^-]|$)' "$doc" | grep -qiE 'never|not|no ' \
  || fail 'migration/build-host.md does not forbid building in ~/homelab'
grep -qiE 'trusted-users' "$doc" \
  || fail 'migration/build-host.md does not say trusted-users is left unset'

if grep -nE 'rsync (-a|--)|--rsync-path' "$doc"; then
  fail 'migration/build-host.md still describes an rsync transport (0002 replaced it with git push)'
fi

if grep -nE '10\.0\.|192\.168\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|ts\.net|/Users/|/home/[a-z]|id_ed25519|[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+' "$doc"; then
  fail 'migration/build-host.md exposes a host, address, user, key path or account'
fi

if command -v gitleaks >/dev/null 2>&1; then
  gitleaks dir --no-banner --redact "$doc" >/dev/null 2>&1 || fail 'gitleaks flagged migration/build-host.md'
fi

if [ "$failures" -gt 0 ]; then
  printf '%s check(s) failed\n' "$failures"
  exit 1
fi
printf 'ok: migration/build-host.md\n'
