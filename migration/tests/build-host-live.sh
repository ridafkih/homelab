#!/bin/sh
set -u

usage() {
  printf 'usage: %s <evidence-dir> <ssh command...>\n' "$0" >&2
  printf 'example: %s ./build-host ssh -o IdentitiesOnly=yes <build-host>\n' "$0" >&2
  exit 2
}

[ "$#" -ge 2 ] || usage
evidence=$1
shift
[ -d "$evidence" ] || { printf 'fail: evidence dir %s is missing\n' "$evidence"; exit 1; }

failures=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  printf 'fail: %s\n' "$1"
  failures=$((failures + 1))
}

box() {
  command=$1
  shift
  "$@" "bash -lc $(printf '%s' "$command" | sed "s/'/'\\\\''/g; s/^/'/; s/\$/'/")"
}

pairs_from_show() {
  awk -F= '/^Id=/{id=$2} /^ActiveEnterTimestampMonotonic=/{print id, $2}' "$1" | sort
}

without_expiry() {
  sed -E 's/ expires [0-9]+sec//'
}

names_from_ps() {
  awk '{print $1}' "$1" | sort
}

strip_flapping() {
  if [ -s "$work/flapping" ]; then
    grep -vF -f "$work/flapping" "$1"
  else
    cat "$1"
  fi
}

for file in preflight.txt install.log pre-docker-ps.txt pre-docker-started.txt pre-units.txt pre-net.txt pre-docker-unit.txt pre-homelab-repo.txt; do
  [ -s "$evidence/$file" ] || fail "evidence file $file is missing or empty"
done
if [ "$failures" -gt 0 ]; then
  printf '%s check(s) failed\n' "$failures"
  exit 1
fi

avail=$(sed -n 's/^root_avail_bytes=\([0-9][0-9]*\)$/\1/p' "$evidence/preflight.txt" | head -n 1)
if [ -z "$avail" ]; then
  fail 'preflight.txt has no root_avail_bytes=<n> line'
elif ! awk -v a="$avail" 'BEGIN { exit !(a > 100000000000) }'; then
  fail "pre-install free space on / was $avail bytes, not over 100 GB, so the install should have aborted"
fi
sed -n 's/^known_flapping=\/\{0,1\}\(.*\)$/\/\1 /p' "$evidence/preflight.txt" > "$work/flapping"

version=$(box 'nix --version' "$@" 2>&1) || fail "nix --version failed: $version"
printf '%s\n' "$version" | grep -q '^nix (Nix) ' || fail "nix --version is not upstream Nix: $version"
case $version in *Determinate*) fail "Determinate Nix was installed instead of upstream Nix: $version" ;; esac

hello=$(box 'nice -n19 ionice -c3 nix run nixpkgs#hello' "$@" 2>&1)
[ "$hello" = 'Hello, world!' ] || fail "nix run nixpkgs#hello printed: $hello"

box 'systemctl show nix-daemon -p Nice -p IOSchedulingClass -p CPUSchedulingPolicy -p MemoryHigh -p MemoryMax' "$@" | sort > "$work/daemon"
printf '%s\n' CPUSchedulingPolicy=3 IOSchedulingClass=3 MemoryHigh=17179869184 MemoryMax=25769803776 Nice=19 > "$work/daemon-expected"
diff "$work/daemon-expected" "$work/daemon" >/dev/null || {
  fail 'nix-daemon limits differ from the drop-in'
  diff "$work/daemon-expected" "$work/daemon"
}
[ "$(box 'systemctl is-active nix-daemon.socket nix-daemon.service | head -n 1' "$@")" = active ] \
  || fail 'nix-daemon.socket is not active'
box 'test -f /etc/systemd/system/nix-daemon.service.d/50-build-host.conf' "$@" \
  || fail 'the 50-build-host.conf drop-in is missing'

box "nix config show | grep -E '^(max-jobs|cores|system-features|experimental-features|min-free|max-free|trusted-users) ' | sort" "$@" > "$work/conf"
cat > "$work/conf-expected" <<'CONF'
cores = 4
experimental-features = flakes nix-command
max-free = 107374182400
max-jobs = 2
min-free = 53687091200
system-features = benchmark big-parallel kvm nixos-test
trusted-users = root
CONF
awk '{ key=$1; $1=$2=""; n=split(substr($0,3), w, " "); if (key == "experimental-features") { m=0; for (i=1;i<=n;i++) if (w[i] != "fetch-tree") w[++m]=w[i]; n=m } for (i=1;i<=n;i++) for (j=i+1;j<=n;j++) if (w[j] < w[i]) { t=w[i]; w[i]=w[j]; w[j]=t } line=key " ="; for (i=1;i<=n;i++) line=line " " w[i]; print line }' "$work/conf" > "$work/conf-sorted"
diff "$work/conf-expected" "$work/conf-sorted" >/dev/null || {
  fail 'nix.conf settings differ from migration/build-host.md'
  diff "$work/conf-expected" "$work/conf-sorted"
}

if grep -q '^installer_path=fallback$' "$evidence/install.log"; then
  printf 'note: install.log records the nixos.org fallback installer\n'
else
  box 'test -x /nix/nix-installer' "$@" || fail '/nix/nix-installer is missing, so the documented uninstall would not work'
fi

[ "$(box 'git -C ~/homelab-nixos-build/repo.git rev-parse --is-bare-repository' "$@" 2>&1)" = true ] \
  || fail '~/homelab-nixos-build/repo.git is not a bare repository'

box "docker ps --format '{{.Names}} {{.Status}}'" "$@" > "$work/post-docker-ps"
names_from_ps "$evidence/pre-docker-ps.txt" > "$work/pre-names"
names_from_ps "$work/post-docker-ps" > "$work/post-names"
diff "$work/pre-names" "$work/post-names" >/dev/null || {
  fail 'running container names changed'
  diff "$work/pre-names" "$work/post-names"
}

box "docker ps -q | xargs docker inspect -f '{{.Name}} {{.State.StartedAt}} {{.RestartCount}}' | sort" "$@" > "$work/post-started-raw"
strip_flapping "$evidence/pre-docker-started.txt" > "$work/pre-started"
strip_flapping "$work/post-started-raw" > "$work/post-started"
diff "$work/pre-started" "$work/post-started" >/dev/null || {
  fail 'a container restarted (StartedAt or RestartCount changed)'
  diff "$work/pre-started" "$work/post-started"
}

box "systemctl list-units --type=service --state=running --no-legend --plain | awk '{print \$1}' | sort | xargs -I{} systemctl show -p Id -p ActiveEnterTimestampMonotonic {}" "$@" > "$work/post-units-raw"
pairs_from_show "$evidence/pre-units.txt" | grep -v '^nix-daemon\.' > "$work/pre-units"
pairs_from_show "$work/post-units-raw" | grep -v '^nix-daemon\.' > "$work/post-units"
diff "$work/pre-units" "$work/post-units" >/dev/null || {
  fail 'a running service other than nix-daemon started, stopped or restarted'
  diff "$work/pre-units" "$work/post-units"
}

box 'ip -br addr; ip rule; ip route show table all' "$@" | without_expiry > "$work/post-net"
without_expiry < "$evidence/pre-net.txt" > "$work/pre-net"
diff "$work/pre-net" "$work/post-net" >/dev/null || {
  fail 'network state changed'
  diff "$work/pre-net" "$work/post-net"
}

box 'ls /etc/systemd/system/docker.service.d/; systemctl show docker -p ActiveEnterTimestampMonotonic' "$@" > "$work/post-docker-unit"
diff "$evidence/pre-docker-unit.txt" "$work/post-docker-unit" >/dev/null || {
  fail 'the docker unit or its drop-ins changed'
  diff "$evidence/pre-docker-unit.txt" "$work/post-docker-unit"
}

box 'git -C ~/homelab rev-parse HEAD; git -C ~/homelab status --porcelain' "$@" > "$work/post-homelab-repo"
diff "$evidence/pre-homelab-repo.txt" "$work/post-homelab-repo" >/dev/null || {
  fail 'the ~/homelab checkout changed'
  diff "$evidence/pre-homelab-repo.txt" "$work/post-homelab-repo"
}

if [ "$failures" -gt 0 ]; then
  printf '%s check(s) failed\n' "$failures"
  exit 1
fi
printf 'ok: build host installed and the live box is unchanged\n'
