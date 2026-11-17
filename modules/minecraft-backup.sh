readonly data_dir=$1 backup_dir=$2 console=$3 keep=$4
umask 077
readonly unit=minecraft-server.service

target="$backup_dir/world-$(date -u +%Y%m%dT%H%M%SZ).tar.zst"

say() {
  printf '%s\n' "$1" > "$console"
}

resume_saving() {
  say save-on
}

flush_world() {
  local cursor deadline
  cursor=$(journalctl -u "$unit" -n 1 --show-cursor -q -o cat | sed -n 's/^-- cursor: //p')
  [[ -n "$cursor" ]] || { echo "minecraft-backup: no journal cursor for $unit" >&2; exit 1; }
  trap resume_saving EXIT
  say save-off
  say "save-all flush"
  deadline=$((SECONDS + 300))
  until journalctl -u "$unit" --after-cursor "$cursor" -o cat | grep -q 'Saved the game'; do
    ((SECONDS < deadline)) || { echo "minecraft-backup: the server never confirmed the save" >&2; exit 1; }
    sleep 2
  done
}

if systemctl is-active --quiet "$unit"; then
  flush_world
fi

install -d -m 0700 "$backup_dir"
tar --zstd -cf "$target.partial" -C "$data_dir" \
  --exclude=./cache --exclude=./libraries --exclude=./versions --exclude=./logs --exclude=./crash-reports .
mv "$target.partial" "$target"
echo "minecraft-backup: wrote $target ($(du -h "$target" | cut -f1))"

mapfile -t stale < <(find "$backup_dir" -maxdepth 1 -name 'world-*.tar.zst' -printf '%f\n' | sort -r | tail -n +$((keep + 1)))
for name in "${stale[@]}"; do
  rm -f -- "$backup_dir/$name"
  echo "minecraft-backup: removed $name"
done
