preferences=${1:?usage: mullvad-exit <preferences.json>}
mullvad_tag=tag:mullvad-exit-node

jq -e 'type == "array"' "$preferences" > /dev/null

status=$(tailscale status --json)
state=$(jq -r '.BackendState' <<< "$status")
if [ "$state" != Running ]; then
  echo "mullvad-exit: tailscale is $state, so the egress floor keeps traffic in"
  exit 0
fi

mullvad_peers() {
  jq -c --arg tag "$mullvad_tag" --slurpfile preferences "$preferences" '
    [(.Peer // {})[]
      | select((.Tags // []) | index($tag))
      | select(.ExitNodeOption and .Online)
      | . as $peer
      | ($peer.Location.CountryCode // "" | ascii_upcase) as $country
      | ($peer.Location.CityCode // "" | ascii_upcase) as $city
      | $peer + {
          PreferenceRank: (
            [$preferences[0] | to_entries[]
              | select(.value.countryCode == $country and (.value.cityCode == null or .value.cityCode == $city))
              | .key]
            | first
          )
        }]' <<< "$status"
}

peers=$(mullvad_peers)
best_rank=$(jq -r '[.[].PreferenceRank | select(. != null)] | min // "none"' <<< "$peers")
if [ "$best_rank" = none ]; then
  pool=$peers
  pool_label="no preferred location online, any Mullvad relay"
else
  pool=$(jq -c --argjson rank "$best_rank" '[.[] | select(.PreferenceRank == $rank)]' <<< "$peers")
  pool_label="preferred location $((best_rank + 1))"
fi

current=$(jq -r '.ExitNodeStatus.ID // ""' <<< "$status")
current_label=$(jq -r '.ExitNodeStatus.ID // "none"' <<< "$status")
prefs=$(tailscale debug prefs)
auto=$(jq -r '.AutoExitNode // ""' <<< "$prefs")
auto_label=$(jq -r 'if (.AutoExitNode // "") == "" then "off" else .AutoExitNode end' <<< "$prefs")

current_in_pool=false
if [ -n "$current" ] && jq -e --arg id "$current" 'any(.[]; .ID == $id)' <<< "$pool" > /dev/null; then
  current_in_pool=true
fi

if [ "$current_in_pool" = true ] && [ -z "$auto" ]; then
  exit 0
fi

if [ "$current_in_pool" = true ]; then
  choice=$(jq -c --arg id "$current" '[.[] | select(.ID == $id)][0]' <<< "$pool")
else
  suggested=$( { tailscale exit-node suggest 2> /dev/null || true; } | sed -n 's/^Suggested exit node: //p' | head -n 1)
  choice=$(jq -c --arg name "$suggested" '[.[] | select(.DNSName == $name)][0] // empty' <<< "$pool")
  if [ -z "$choice" ]; then
    choice=$(jq -c 'sort_by(-(.Location.Priority // 0), .ID) | .[0] // empty' <<< "$pool")
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

choice_ip=$(jq -r '.TailscaleIPs[0]' <<< "$choice")
choice_name=$(jq -r '.DNSName' <<< "$choice")
echo "mullvad-exit: pinning Mullvad exit node $choice_name $choice_ip, $pool_label (was $current_label, auto $auto_label)"
tailscale set --exit-node="$choice_ip"
