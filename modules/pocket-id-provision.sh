readonly spec=$1
readonly api=$2
readonly api_key_file=$3
readonly secrets_dir=$4

api_key=$(<"$api_key_file")

call() {
  local method=$1 path=$2
  shift 2
  curl -fsS --retry 5 --retry-connrefused --retry-delay 2 -X "$method" \
    -H "X-API-Key: $api_key" -H "Content-Type: application/json" "$@" "$api$path"
}

group_id() {
  call GET "/user-groups?pagination%5Blimit%5D=1000" | jq -r --arg name "$1" '.data[] | select(.name == $name) | .id'
}

ensure_group() {
  local name=$1 friendly=$2 id
  id=$(group_id "$name")
  if [[ -z "$id" ]]; then
    call POST /user-groups --data "$(jq -n --arg name "$name" --arg friendly "$friendly" '{name: $name, friendlyName: $friendly}')" > /dev/null
    echo "created group $name"
  fi
}

client_body() {
  jq -c --argjson groupRestricted "$2" '{name, callbackURLs, logoutCallbackURLs, isPublic, pkceEnabled, isGroupRestricted: $groupRestricted}' <<<"$1"
}

ensure_secret() {
  local id=$1 secret prefix
  secret=$(<"$secrets_dir/$id")
  prefix=${secret:0:4}
  if ! call GET "/oidc/clients/$id/secrets" | jq -e --arg prefix "$prefix" 'any(.[]; .prefix == $prefix and .isActive)' > /dev/null; then
    call POST "/oidc/clients/$id/secrets" --data "$(jq -n --arg secret "$secret" '{secret: $secret, expiresAt: null}')" > /dev/null
    echo "set the secret of client $id"
  fi
  call GET "/oidc/clients/$id/secrets" | jq -r --arg prefix "$prefix" '.[] | select(.prefix != $prefix) | .id' | while read -r stale; do
    call DELETE "/oidc/clients/$id/secrets/$stale" > /dev/null
    echo "removed a stale secret of client $id"
  done
}

ensure_client() {
  local client=$1 id groups restricted group_ids
  id=$(jq -r .id <<<"$client")
  groups=$(jq -c .groups <<<"$client")
  restricted=$(jq 'length > 0' <<<"$groups")
  if call GET "/oidc/clients/$id" > /dev/null 2>&1; then
    call PUT "/oidc/clients/$id" --data "$(client_body "$client" "$restricted")" > /dev/null
  else
    call POST /oidc/clients --data "$(client_body "$client" "$restricted" | jq -c --arg id "$id" '. + {id: $id}')" > /dev/null
    echo "created client $id"
  fi
  group_ids=$(jq -r '.[]' <<<"$groups" | while read -r name; do group_id "$name"; done | jq -R . | jq -sc .)
  call PUT "/oidc/clients/$id/allowed-user-groups" --data "$(jq -n --argjson ids "$group_ids" '{userGroupIds: $ids}')" > /dev/null
  if [[ $(jq -r .isPublic <<<"$client") == false ]]; then
    ensure_secret "$id"
  fi
}

jq -c '.groups[]' "$spec" | while read -r group; do
  ensure_group "$(jq -r .name <<<"$group")" "$(jq -r .friendlyName <<<"$group")"
done

jq -c '.clients[]' "$spec" | while read -r client; do
  ensure_client "$client"
done
