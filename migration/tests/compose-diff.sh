#!/bin/sh
set -eu

baseline=9af811a
digest=sha256:a5d0ce49aa801d475da48f8cb163c354ab95cab073cd3c138bd458fc8257fbf1

for tool in docker-compose jq git diff; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool"; exit 2; }
done

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
git -C "$repo" cat-file -e "$baseline^{commit}" 2>/dev/null || { echo "baseline $baseline is not in $repo"; exit 2; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/compose-diff-tests.XXXXXX")
trap 'rm -rf "$scratch"' EXIT INT TERM

export DOCKER_HOST="unix://$scratch/no-docker-daemon.sock"

ran=0
failures=0

pass() { ran=$((ran + 1)); }
fail() { ran=$((ran + 1)); failures=$((failures + 1)); echo "FAIL: $1"; }
check() { if [ "$2" = "$3" ]; then pass; else fail "$1: expected [$3], got [$2]"; fi; }

work="$scratch/repo"
git clone -q --shared --no-checkout "$repo" "$work"
git -C "$work" checkout -q --detach "$(git -C "$repo" rev-parse HEAD)"
for path in compose.yaml homelab.env apps migration secrets; do
  rm -rf "${work:?}/$path"
  if [ -e "$repo/$path" ]; then cp -R "$repo/$path" "$work/$path"; fi
done


reset_apps() {
  rm -rf "${work:?}/apps"
  if [ -e "$repo/apps" ]; then cp -R "$repo/apps" "$work/apps"; fi
}

diff_out=""
diff_rc=0
run_diff() {
  diff_rc=0
  diff_out=$(cd "$work" && sh migration/compose-diff.sh "$@" 2>&1) || diff_rc=$?
}

changed_lines() {
  printf '%s\n' "$diff_out" | grep -E '^[-+]' | grep -vE '^(---|\+\+\+) '
}

trailer_lists() {
  printf '%s\n' "$diff_out" | grep -Eq "^[[:space:]-]*$1\$"
}

show_diff() {
  printf '%s\n' "$diff_out" | sed 's/^/    | /'
}

mkdir -p "$work/apps/open-webui"
cat > "$work/apps/open-webui/compose.yaml" <<'EOF'
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    volumes:
      - ${HOMELAB_DATA_DIR:?}/open-webui/app/backend/data:/app/backend/data
    restart: always
    networks:
      - homelab-network
EOF
run_diff homelab compose.yaml apps/open-webui/compose.yaml
check "diff pure move from .data to HOMELAB_DATA_DIR exit" "$diff_rc" "0"
check "diff pure move changed lines" "$(changed_lines)" ""
[ "$diff_rc" = 0 ] || show_diff
for dropped in caddy jellyfin seafile-redis grafana; do
  if trailer_lists "$dropped"; then pass; else fail "diff trailer does not list old-only service $dropped"; fi
done
if trailer_lists open-webui; then fail "diff trailer lists moved service open-webui"; else pass; fi
if printf '%s\n' "$diff_out" | grep -qF "$scratch"; then fail "diff output leaks scratch paths"; else pass; fi

sed -i.orig 's/container_name: open-webui$/container_name: open-webui-renamed/' "$work/apps/open-webui/compose.yaml"
run_diff homelab compose.yaml apps/open-webui/compose.yaml
check "diff renamed container exit" "$diff_rc" "1"
if changed_lines | grep -q '^-.*"open-webui"' && changed_lines | grep -q '^+.*"open-webui-renamed"'; then pass; else fail "diff does not show the container_name change"; show_diff; fi
mv "$work/apps/open-webui/compose.yaml.orig" "$work/apps/open-webui/compose.yaml"

cat >> "$work/apps/open-webui/compose.yaml" <<'EOF'
    ports:
      - 3000:8080
EOF
run_diff homelab compose.yaml apps/open-webui/compose.yaml
check "diff added port exit" "$diff_rc" "1"
if changed_lines | grep -q '^+.*3000'; then pass; else fail "diff does not show the added port"; show_diff; fi

cat > "$work/apps/open-webui/compose.yaml" <<'EOF'
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    volumes:
      - ${HOMELAB_DATA_DIR:?}/openwebui-moved:/app/backend/data
    restart: always
    networks:
      - homelab-network
EOF
run_diff homelab compose.yaml apps/open-webui/compose.yaml
check "diff moved bind exit" "$diff_rc" "1"
if changed_lines | grep -q '^+.*"<repo>/.data/openwebui-moved"' && changed_lines | grep -q '^-.*"<repo>/.data/open-webui/app/backend/data"'; then pass; else fail "diff does not show the bind move with <repo> paths"; show_diff; fi

cat > "$work/apps/open-webui/compose.yaml" <<EOF
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    volumes:
      - \${HOMELAB_DATA_DIR:?}/open-webui/app/backend/data:/app/backend/data
    restart: always
    networks:
      - homelab-network
  brand-new:
    image: docker.io/library/busybox:1.37.0@$digest
    container_name: brand-new
    networks:
      - homelab-network
EOF
run_diff homelab compose.yaml apps/open-webui/compose.yaml
check "diff new service exit" "$diff_rc" "1"
if changed_lines | grep -q '^+.*brand-new'; then pass; else fail "diff does not show the service missing from the old side"; show_diff; fi
reset_apps

mkdir -p "$work/apps/observability"
cat > "$work/apps/observability/compose.yaml" <<EOF
services:
  grafana-funnel:
    image: tailscale/tailscale:latest
    container_name: tailscale-funnel
    restart: unless-stopped
    hostname: otel-funnel
    env_file:
      - \${HOMELAB_SECRETS_DIR:?}/tailscale-funnel.env
    environment:
      - TS_STATE_DIR=/var/lib/tailscale
      - TS_SERVE_CONFIG=/config/serve.json
    volumes:
      - grafana-funnel:/var/lib/tailscale
      - $work/config/tailscale-serve.json:/config/serve.json:ro
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    networks:
      - homelab-network

volumes:
  grafana-funnel:
    driver: local
EOF
run_diff homelab compose.yaml apps/observability/compose.yaml
check "diff interpolated secret to env_file exit" "$diff_rc" "0"
check "diff interpolated secret to env_file changed lines" "$(changed_lines)" ""
[ "$diff_rc" = 0 ] || show_diff
if printf '%s\n' "$diff_out" | grep -qF "$work"; then fail "diff output leaks the workspace path"; else pass; fi

sed -i.orig '/TS_SERVE_CONFIG/d' "$work/apps/observability/compose.yaml"
run_diff homelab compose.yaml apps/observability/compose.yaml
check "diff dropped environment key exit" "$diff_rc" "1"
if changed_lines | grep -q '^-.*TS_SERVE_CONFIG'; then pass; else fail "diff does not show the dropped environment key"; show_diff; fi
if changed_lines | grep -q 'TS_AUTHKEY'; then fail "diff shows the env_file secret as changed"; show_diff; else pass; fi
reset_apps

mkdir -p "$work/apps/openseo"
git -C "$repo" show "$baseline:openseo/compose.yaml" > "$work/apps/openseo/compose.yaml"
run_diff openseo openseo/compose.yaml apps/openseo/compose.yaml
if [ "$diff_rc" -le 1 ]; then pass; else fail "diff openseo standalone render exit $diff_rc"; show_diff; fi
if changed_lines | grep -qE 'AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|RUSTFS_'; then fail "diff openseo shows storage secrets as changed"; show_diff; else pass; fi
rm -rf "$work/apps/openseo"
reset_apps

printf 'services:\n  oldside:\n    image: busybox:latest\n' > "$work/moved-after-baseline.yaml"
git -C "$work" add moved-after-baseline.yaml
git -C "$work" -c user.name=t -c user.email=t@t commit -q -m t
run_diff homelab moved-after-baseline.yaml apps/open-webui/compose.yaml
check "diff old path absent from $baseline" "$diff_rc" "2"

run_diff homelab compose.yaml apps/does-not-exist/compose.yaml
check "diff missing new file" "$diff_rc" "2"
run_diff homelab compose.yaml
check "diff wrong argument count" "$diff_rc" "2"
run_diff nope compose.yaml apps/open-webui/compose.yaml
check "diff unknown project" "$diff_rc" "2"

if [ "$ran" = 0 ]; then
  echo "no test cases ran"
  exit 1
fi
echo "$ran checks, $failures failed"
[ "$failures" = 0 ]
