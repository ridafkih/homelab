mullvad_tag=tag:mullvad-exit-node

status=$(tailscale status --json)
state=$(jq -r '.BackendState' <<< "$status")
if [ "$state" != Running ]; then
  echo "mullvad-exit: tailscale is $state, so the egress floor keeps traffic in"
  exit 0
fi

mullvad_peers() {
  jq -c --arg tag "$mullvad_tag" '[(.Peer // {})[] | select((.Tags // []) | index($tag)) | select(.ExitNodeOption and .Online)]' <<< "$status"
}

peers=$(mullvad_peers)
current=$(jq -r '.ExitNodeStatus.ID // ""' <<< "$status")
current_label=$(jq -r '.ExitNodeStatus.ID // "none"' <<< "$status")
prefs=$(tailscale debug prefs)
auto=$(jq -r '.AutoExitNode // ""' <<< "$prefs")
auto_label=$(jq -r 'if (.AutoExitNode // "") == "" then "off" else .AutoExitNode end' <<< "$prefs")

current_is_mullvad=false
if [ -n "$current" ] && jq -e --arg id "$current" 'any(.[]; .ID == $id)' <<< "$peers" > /dev/null; then
  current_is_mullvad=true
fi

if [ "$current_is_mullvad" = true ] && [ -z "$auto" ]; then
  exit 0
fi

if [ "$current_is_mullvad" = true ]; then
  choice=$(jq -r --arg id "$current" '.[] | select(.ID == $id) | .TailscaleIPs[0]' <<< "$peers")
else
  suggested=$( { tailscale exit-node suggest 2> /dev/null || true; } | sed -n 's/^Suggested exit node: //p' | head -n 1)
  choice=$(jq -r --arg name "$suggested" '[.[] | select(.DNSName == $name)][0].TailscaleIPs[0] // ""' <<< "$peers")
  if [ -z "$choice" ]; then
    choice=$(jq -r 'sort_by(-(.Location.Priority // 0), .ID) | .[0].TailscaleIPs[0] // ""' <<< "$peers")
  fi
fi

if [ -z "$choice" ]; then
  if [ -n "$current" ] || [ -n "$auto" ]; then
    echo "mullvad-exit: no online Mullvad exit node; clearing exit node $current_label (auto $auto_label) so the egress floor keeps traffic in" >&2
    tailscale set --exit-node=
  else
    echo "mullvad-exit: no online Mullvad exit node; with no exit node the egress floor keeps traffic in" >&2
  fi
  exit 1
fi

echo "mullvad-exit: pinning Mullvad exit node $choice (was $current_label, auto $auto_label)"
tailscale set --exit-node="$choice"
