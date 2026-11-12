readonly plugin_source=$1
readonly plugin_dir=$2
readonly sso_template=$3
readonly sso_file=$4
readonly secret_file=$5
readonly branding_template=$6
readonly branding_file=$7
readonly owner=$8

user=${owner%:*}
group=${owner#*:}
changed=false

place() {
  local source=$1 target=$2 mode=$3
  if ! cmp -s "$source" "$target"; then
    install -D -o "$user" -g "$group" -m "$mode" "$source" "$target"
    changed=true
  fi
}

if ! cmp -s "$plugin_source/SSO-Auth.dll" "$plugin_dir/SSO-Auth.dll"; then
  rm -rf "$plugin_dir"
  install -d -o "$user" -g "$group" -m 0755 "$plugin_dir"
  install -o "$user" -g "$group" -m 0644 "$plugin_source"/* "$plugin_dir"/
  changed=true
fi

rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT
secret=$(<"$secret_file")
awk -v secret="$secret" '{ gsub(/@CLIENT_SECRET@/, secret); print }' "$sso_template" > "$rendered"
place "$rendered" "$sso_file" 0600
place "$branding_template" "$branding_file" 0644

if [[ $changed == true ]] && [[ $(docker inspect -f '{{.State.Running}}' jellyfin 2>/dev/null) == true ]]; then
  docker restart jellyfin > /dev/null
  echo "restarted jellyfin to load the SSO plugin and the sign-in button"
fi
