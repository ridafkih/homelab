#!/usr/bin/env bash
set -euo pipefail

vault=${1:?usage: secrets-age-keys.sh <1password vault>}

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

for tool in op jq age-keygen stat; do
  command -v "$tool" > /dev/null || { echo "missing tool: $tool"; exit 1; }
done

token_file="$HOME/.config/op/service-account-token"
test -s "$token_file" || { echo "missing 1Password service account token"; exit 1; }
OP_SERVICE_ACCOUNT_TOKEN=$(< "$token_file")
export OP_SERVICE_ACCOUNT_TOKEN

host_title="homelab sops host age key"
admin_title="homelab sops admin age key"
admin_dir="$HOME/.config/sops/age"
admin_file="$admin_dir/age.key"

failures=0
fail() {
  echo "$1"
  failures=$((failures + 1))
}

mode_of() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

titles=$(op item list --vault "$vault" --format json | jq -r '.[].title')
grep -qxF "$host_title" <<< "$titles" || fail "1Password item missing: $host_title"
grep -qxF "$admin_title" <<< "$titles" || fail "1Password item missing: $admin_title"

recipient_from_item() {
  op item get "$1" --vault "$vault" --format json --reveal \
    | jq -r '[.fields[]?.value // empty | scan("AGE-SECRET-KEY-1[0-9A-Z]+")] | unique | if length == 1 then .[0] else error("expected one identity") end' \
    | age-keygen -y 2>/dev/null
}

test -d "$admin_dir" || fail "missing $admin_dir"
test -f "$admin_file" || fail "missing admin key file"
if test -d "$admin_dir"; then
  [ "$(mode_of "$admin_dir")" = 700 ] || fail "admin key dir must be 0700"
  others=$(find "$admin_dir" -mindepth 1 ! -path "$admin_file" | wc -l | tr -d ' ')
  [ "$others" = 0 ] || fail "admin key dir holds $others files besides age.key"
fi

test_recipient=$(age-keygen -y secrets/test-age.key 2>/dev/null || fail "missing or unreadable secrets/test-age.key")
sops_recipients=$(grep -oE 'age1[0-9a-z]{58}' .sops.yaml | sort -u | grep -vxF "$test_recipient" || true)
[ "$(wc -l <<< "$sops_recipients" | tr -d ' ')" = 2 ] || fail ".sops.yaml must name exactly two production recipients"

if test -f "$admin_file"; then
  [ "$(mode_of "$admin_file")" = 600 ] || fail "admin key file must be 0600"
  admin_recipient=$(age-keygen -y "$admin_file")
  grep -qxF "$admin_recipient" <<< "$sops_recipients" || fail "admin key file is not a .sops.yaml recipient"
  [ "$(recipient_from_item "$admin_title" || true)" = "$admin_recipient" ] \
    || fail "1Password admin item does not hold the admin key file's identity"
  host_recipient=$(grep -vxF "$admin_recipient" <<< "$sops_recipients" || true)
  if [ -n "$host_recipient" ]; then
    [ "$(recipient_from_item "$host_title" || true)" = "$host_recipient" ] \
      || fail "1Password host item does not hold the host recipient's identity"
  fi
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures age key checks failed"
  exit 1
fi
echo "ok: age keys are in 1Password and match .sops.yaml"
