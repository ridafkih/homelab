usage() {
  echo "usage: sudo pocket-id-invite USERNAME EMAIL FIRST_NAME LAST_NAME [GROUP]..." >&2
  echo "Creates the Pocket ID user if missing, sets its groups and prints a one-time sign-in link." >&2
  exit 2
}

[[ $# -ge 4 ]] || usage
readonly username=$1 email=$2 first=$3 last=$4
shift 4
readonly groups=("$@")
is_admin=false
for group in "${groups[@]}"; do
  if [[ $group == admins ]]; then
    is_admin=true
  fi
done

readonly api=@api@
readonly app_url=@appUrl@
readonly api_key_file=@apiKeyFile@
readonly ttl=72h
api_key=$(<"$api_key_file")

call() {
  local method=$1 path=$2
  shift 2
  curl -fsS -X "$method" -H "X-API-Key: $api_key" -H "Content-Type: application/json" "$@" "$api$path"
}

user_id=$(call GET "/users?pagination%5Blimit%5D=1000" | jq -r --arg username "$username" '.data[] | select(.username == $username) | .id')
if [[ -z "$user_id" ]]; then
  user_id=$(call POST /users --data "$(jq -n --arg username "$username" --arg email "$email" --arg first "$first" --arg last "$last" --argjson admin "$is_admin" \
    '{username: $username, email: $email, emailVerified: true, firstName: $first, lastName: $last, isAdmin: $admin}')" | jq -r .id)
  echo "created $username ($user_id)" >&2
fi

all_groups=$(call GET "/user-groups?pagination%5Blimit%5D=1000")
group_ids=$(for group in "${groups[@]}"; do
  jq -er --arg name "$group" '.data[] | select(.name == $name) | .id' <<<"$all_groups" || { echo "no group named $group" >&2; exit 1; }
done | jq -R . | jq -sc .)
call PUT "/users/$user_id/user-groups" --data "$(jq -n --argjson ids "$group_ids" '{userGroupIds: $ids}')" > /dev/null

token=$(call POST "/users/$user_id/one-time-access-token" --data "$(jq -n --arg ttl "$ttl" '{ttl: $ttl}')" | jq -r .token)
echo "$app_url/lc/$token"
