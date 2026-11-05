#!/usr/bin/env bash
set -euo pipefail

: "${SIGNOZ_URL:?set SIGNOZ_URL to the SigNoz base URL}"
: "${SIGNOZ_API_KEY:?set SIGNOZ_API_KEY to an admin service-account key}"

readonly logs_days=30
readonly traces_hours=720
readonly metrics_hours=2160
dashboards_dir="$(cd -- "$(dirname -- "$0")" && pwd)/dashboards"
readonly dashboards_dir

call() {
  curl -sS --fail-with-body -X "$1" -H "SIGNOZ-API-KEY: $SIGNOZ_API_KEY" "$SIGNOZ_URL$2"
}

send() {
  curl -sS --fail-with-body -X "$1" -H "SIGNOZ-API-KEY: $SIGNOZ_API_KEY" -H "Content-Type: application/json" --data-binary "@$3" "$SIGNOZ_URL$2"
}

apply_retention() {
  local body
  body=$(mktemp)
  jq -n --argjson days "$logs_days" '{type: "logs", defaultTTLDays: $days, ttlConditions: []}' > "$body"
  send POST /api/v2/settings/ttl "$body" > /dev/null
  rm -f "$body"
  call POST "/api/v1/settings/ttl?type=traces&duration=${traces_hours}h" > /dev/null
  call POST "/api/v1/settings/ttl?type=metrics&duration=${metrics_hours}h" > /dev/null
  echo "retention: logs ${logs_days}d, traces ${traces_hours}h, metrics ${metrics_hours}h"
}

upsert_dashboards() {
  local existing file name id
  existing=$(call GET /api/v2/dashboards | jq -c '[.data.dashboards[] | {(.name): .id}] | add // {}')
  for file in "$dashboards_dir"/*.json; do
    name=$(jq -r .name "$file")
    id=$(jq -r --arg name "$name" '.[$name] // empty' <<< "$existing")
    if [ -n "$id" ]; then
      send PUT "/api/v2/dashboards/$id" "$file" > /dev/null
      echo "updated $name $SIGNOZ_URL/dashboard/$id"
    else
      id=$(send POST /api/v2/dashboards "$file" | jq -r .data.id)
      echo "created $name $SIGNOZ_URL/dashboard/$id"
    fi
  done
}

apply_retention
upsert_dashboards
