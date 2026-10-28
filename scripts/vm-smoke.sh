#!/bin/sh
set -eu

usage() {
  echo "usage: vm-smoke.sh [--down <service>] core|media|obs" >&2
  exit 2
}

refuse() {
  echo "vm-smoke.sh: $*" >&2
  exit 2
}

down=""
if [ "$#" -ge 1 ] && [ "$1" = --down ]; then
  [ "$#" -ge 2 ] || usage
  down=$2
  shift 2
fi
[ "$#" -eq 1 ] || usage
tier=$1
case "$1" in
  core) boots=core ;;
  media) boots=media ;;
  obs) boots="obs-signoz obs-grafana" ;;
  *) usage ;;
esac
case "$down" in
  *[!A-Za-z0-9_-]*) refuse "--down takes a compose service name" ;;
esac
down_label=none
[ -z "$down" ] || down_label=$down

here=$(pwd -P)
build_root=$(cd "$HOME/homelab-nixos-build" 2>/dev/null && pwd -P) || refuse "$HOME/homelab-nixos-build does not exist"
if live=$(cd "$HOME/homelab" 2>/dev/null && pwd -P); then
  case "$here/" in
    "$live"/*) refuse "refusing to run inside the live checkout $live" ;;
  esac
fi
case "$here/" in
  "$build_root"/*/) ;;
  *) refuse "run from a clone inside $build_root" ;;
esac

PATH=/nix/var/nix/profiles/default/bin:$PATH
export PATH

state=$here/.vm-smoke
mkdir -p "$state"

exec 9>"$build_root/.vm-smoke.lock"
flock -n 9 || refuse "another vm-smoke run holds $build_root/.vm-smoke.lock"

cleanup() {
  for boot in $boots; do
    systemctl --user stop "vm-smoke-$boot-$$.scope" 2> /dev/null || true
    rm -f "$state/$boot"/*.qcow2
    rm -rf "$state/$boot/tmp"
  done
  rm -f "$state/result"
}
trap cleanup EXIT
cleanup

cat > "$state/scope.sh" <<'EOF'
cgroup=/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)
echo 0 > "$2/anon.peak"
while :; do
  awk -v file="$2/anon.peak" '$1 == "anon" { getline peak < file; if ($2 > peak) print $2 > file }' "$cgroup/memory.stat"
  sleep 5
done &
sampler=$!
nice -n19 ionice -c3 timeout --foreground 40m "$1" < /dev/null > "$2/serial.log" 2>&1
code=$?
kill "$sampler"
cat "$cgroup/memory.peak" > "$2/memory.peak"
awk '$1 == "oom_kill" { print $2 }' "$cgroup/memory.events" > "$2/oom_kill"
exit "$code"
EOF
trap 'exit 130' INT
trap 'exit 143' TERM

[ -w /dev/kvm ] || refuse "/dev/kvm is not writable"
mem_available_mib=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
[ "$mem_available_mib" -ge 16384 ] || refuse "only $mem_available_mib MiB available; need 16384 to leave the live box headroom"
disk_free_gib=$(df -P -BG "$build_root" | awk 'NR == 2 { sub(/G$/, "", $4); print $4 }')
[ "$disk_free_gib" -ge 150 ] || refuse "only $disk_free_gib GiB free under $build_root; need 150"

snapshot() {
  docker ps -q --no-trunc | sort | while read -r id; do
    docker inspect --format '{{.Name}} {{.Id}} {{.State.StartedAt}} {{.RestartCount}}' "$id"
  done > "$1.docker"
  ss -ltnH | awk '{ print $4 }' | sort -u > "$1.listen"
}

compare() {
  if ! diff -u "$1.docker" "$2.docker"; then
    echo "live containers changed (name, ID, StartedAt, RestartCount)" >&2
    return 1
  fi
  if ! diff -u "$1.listen" "$2.listen"; then
    echo "listening TCP sockets changed (ss -ltn)" >&2
    return 1
  fi
}

snapshot "$state/before"

nice -n19 ionice -c3 nix build -L --no-update-lock-file .#checks.x86_64-linux.vm-smoke --no-link
vm=$(nice -n19 ionice -c3 nix build --no-update-lock-file --print-out-paths --out-link "$state/result" .#nixosConfigurations.homelab.config.system.build.vm)
runner=$(find "$vm/bin" -name 'run-*-vm' | head -n1)
[ -x "$runner" ] || refuse "no run-*-vm script in $vm/bin"

kernel_params() {
  if [ -n "$down" ]; then
    printf 'homelab.smoke=%s homelab.smoke.down=%s' "$1" "$down"
  else
    printf 'homelab.smoke=%s' "$1"
  fi
}

measurements=$state/measurements.tsv
[ -s "$measurements" ] || printf 'date\tcommit\tboot\tdown\tverdict\tguest_peak_mib\thost_anon_peak_mib\thost_peak_mib\thost_oom_kill\tsettle_seconds\tqemu_exit\n' > "$measurements"
commit=$(git rev-parse --short HEAD)
overall=0

for boot in $boots; do
  dir=$state/$boot
  rm -rf "$dir"
  mkdir -p "$dir/tmp"
  echo "== $boot: booting $(kernel_params "$boot")"
  set +e
  NIX_DISK_IMAGE="$dir/root.qcow2" TMPDIR="$dir/tmp" USE_TMPDIR=1 QEMU_KERNEL_PARAMS="$(kernel_params "$boot")" \
    systemd-run --user --scope --quiet -p MemoryMax=7G --unit="vm-smoke-$boot-$$" \
    sh "$state/scope.sh" "$runner" "$dir" 9>&-
  qemu_exit=$?
  set -e

  summary=$dir/tmp/xchg/summary.tsv
  host_peak_mib=$(( $(cat "$dir/memory.peak") / 1048576 ))
  host_anon_peak_mib=$(( $(cat "$dir/anon.peak") / 1048576 ))
  host_oom=$(cat "$dir/oom_kill")
  verdict=missing
  guest_peak=none
  settle=none
  if [ -s "$summary" ]; then
    cp "$dir"/tmp/xchg/* "$dir"/
    verdict=$(awk -F '\t' '$1 == "verdict" { print $2 }' "$summary")
    guest_peak=$(awk -F '\t' '$1 == "guest_peak_mib" { print $2 }' "$summary")
    settle=$(awk -F '\t' '$1 == "settle_seconds" { print $2 }' "$summary")
    awk -F '\t' '$1 == "container" || $1 == "route" || $1 == "unit" || $1 == "failure" || $1 == "expected_failure" || $1 == "kernel_oom" || $1 ~ /^db_dump/' "$summary"
  else
    echo "$boot: the guest wrote no summary; see $dir/serial.log" >&2
  fi
  [ -n "$verdict" ] || verdict=missing

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$commit" "$boot" "$down_label" "$verdict" "$guest_peak" "$host_anon_peak_mib" "$host_peak_mib" "$host_oom" "$settle" "$qemu_exit" \
    >> "$measurements"
  echo "== $boot: verdict=$verdict guest_peak_mib=$guest_peak host_anon_peak_mib=$host_anon_peak_mib host_peak_mib=$host_peak_mib host_oom_kill=$host_oom settle_seconds=$settle qemu_exit=$qemu_exit"

  rm -f "$dir"/*.qcow2
  rm -rf "$dir/tmp"

  if [ "$verdict" != pass ] || [ "$host_oom" != 0 ] || [ "$qemu_exit" != 0 ]; then
    overall=1
  fi
done

snapshot "$state/after"
if compare "$state/before" "$state/after"; then
  echo "== live box: containers and listening sockets unchanged"
else
  overall=1
fi

leftover=$(find "$build_root" -name '*.qcow2' -print)
if [ -n "$leftover" ]; then
  echo "qcow2 images left under $build_root:" >&2
  echo "$leftover" >&2
  overall=1
else
  echo "== no qcow2 left under $build_root"
fi

if [ "$overall" -eq 0 ]; then
  echo "== vm-smoke $tier: pass"
else
  echo "== vm-smoke $tier: fail"
fi
exit "$overall"
