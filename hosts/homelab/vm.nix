{ lib, self, ... }:
let
  caddySource = builtins.readFile ../../apps/caddy/Caddyfile;
  cloudflareImport = "import cloudflare";

  tiers = {
    core = [
      "caddy"
      "adguard-init"
      "adguard"
      "authentik-postgresql"
      "authentik-redis"
      "authentik-server"
      "authentik-worker"
      "authentik-cloudflared"
      "ridash-cloudflared"
      "seafile-db"
      "seafile-redis"
      "seafile"
      "seadoc"
      "jellyfin"
    ];
    media = [
      "caddy"
      "prowlarr"
      "sonarr"
      "radarr"
      "bazarr"
      "qbittorrent"
      "qui"
      "jellyseerr"
      "open-webui"
    ];
    obs-signoz = [
      "caddy"
      "signoz-init-clickhouse"
      "signoz-zookeeper"
      "signoz-clickhouse"
      "signoz-telemetrystore-migrator"
      "signoz"
      "signoz-otel-collector"
    ];
    obs-grafana = [
      "caddy"
      "tempo"
      "prometheus"
      "loki"
      "grafana"
      "grafana-funnel"
      "otel-collector"
    ];
  };

  expectedFailures = [ "authentik-cloudflared" "ridash-cloudflared" "grafana-funnel" ];
  openseoTier = "core";
  stateDir = "/run/homelab-smoke";
  tierFile = "${stateDir}/tier.yaml";
  results = "/tmp/xchg";
  healthWindowSeconds = 600;
  stableSeconds = 60;

  dataDisk = serial: {
    device = "/dev/disk/by-id/virtio-${serial}";
    fsType = "ext4";
    autoFormat = true;
    options = [ "defaults" "nofail" "noatime" "x-systemd.device-timeout=15s" ];
  };

  emptyDisk = serial: {
    size = 20480;
    driveConfig.deviceExtraOpts.serial = serial;
  };
in
{
  virtualisation.vmVariant = { config, pkgs, ... }:
    let
      checkout = config.homelab.checkoutDir;
      secrets = config.homelab.secrets;
      docker = config.virtualisation.docker.package;
      user = config.homelab.user;

      vmCaddyfile =
        if lib.hasInfix cloudflareImport caddySource then
          pkgs.writeText "Caddyfile" (builtins.replaceStrings [ cloudflareImport ] [ "tls internal" ] caddySource)
        else
          throw "apps/caddy/Caddyfile no longer contains '${cloudflareImport}', so the VM cannot switch it to tls internal";

      caddyOverride = pkgs.writeText "compose.caddy-vm.yaml" (
        builtins.toJSON { services.caddy.volumes = [ "${vmCaddyfile}:/etc/caddy/Caddyfile:ro" ]; }
      );

      nogpuOverride = ../../apps/jellyfin/compose.nogpu.yaml;

      tiersJson = pkgs.writeText "homelab-smoke-tiers.json" (
        builtins.toJSON { inherit tiers expectedFailures openseoTier; }
      );

      composeEnvironment = {
        HOMELAB_DATA_DIR = config.homelab.dataDir;
        HOMELAB_SECRETS_DIR = secrets.envDir;
      };

      homelabCompose = lib.escapeShellArgs [
        "docker"
        "compose"
        "-p"
        "homelab"
        "--project-directory"
        checkout
        "-f"
        "${checkout}/compose.yaml"
        "-f"
        "${nogpuOverride}"
        "-f"
        "${caddyOverride}"
        "--env-file"
        "${checkout}/homelab.env"
      ];

      openseoCompose = lib.escapeShellArgs [
        "docker"
        "compose"
        "-p"
        "openseo"
        "--project-directory"
        "${checkout}/apps/openseo"
        "-f"
        "${checkout}/apps/openseo/compose.yaml"
        "--env-file"
        "${checkout}/apps/openseo/openseo.env"
        "--env-file"
        secrets.templates."openseo.env"
      ];

      checkoutScript = pkgs.writeShellApplication {
        name = "homelab-vm-checkout";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          mkdir -p ${checkout}
          cp -rT --no-preserve=mode,ownership ${self} ${checkout}
          chown -R ${user}:${user} ${checkout}
        '';
      };

      tierScript = pkgs.writeShellApplication {
        name = "homelab-smoke-tier";
        runtimeInputs = [ docker pkgs.jq pkgs.coreutils ];
        text = ''
          tier=""
          down=""
          read -r -a params < /proc/cmdline
          for param in "''${params[@]}"; do
            case "$param" in
              homelab.smoke=*) tier=''${param#homelab.smoke=} ;;
              homelab.smoke.down=*) down=''${param#homelab.smoke.down=} ;;
            esac
          done

          mkdir -p ${stateDir}
          printf '%s\n' "$tier" > ${stateDir}/tier
          printf '%s\n' "$down" > ${stateDir}/down

          if [ -z "$tier" ]; then
            printf '%s\n' '{"services":{}}' > ${tierFile}
            exit 0
          fi

          if ! jq -e --arg tier "$tier" '.tiers | has($tier)' ${tiersJson} > /dev/null; then
            echo "homelab.smoke=$tier is not one of: $(jq -r '.tiers | keys | join(" ")' ${tiersJson})" >&2
            exit 1
          fi

          ${homelabCompose} config --format json > ${stateDir}/homelab.json

          uncovered=$(jq -r --slurpfile spec ${tiersJson} \
            '[.services | keys[]] - ([$spec[0].tiers[]] | add | unique) | join(" ")' ${stateDir}/homelab.json)
          unknown=$(jq -r --slurpfile spec ${tiersJson} \
            '([$spec[0].tiers[]] | add | unique) - [.services | keys[]] | join(" ")' ${stateDir}/homelab.json)
          if [ -n "$uncovered" ] || [ -n "$unknown" ]; then
            echo "tier coverage broken: services in no tier: [$uncovered]; tier names not in compose: [$unknown]" >&2
            exit 1
          fi

          open=$(jq -r --slurpfile spec ${tiersJson} --arg tier "$tier" '
            $spec[0].tiers[$tier] as $members
            | [.services | to_entries[] | select(.key as $name | $members | index($name))
               | .key as $name | (.value.depends_on // {} | keys[]) | select(. as $dep | $members | index($dep) | not)
               | "\($name)->\(.)"] | join(" ")' ${stateDir}/homelab.json)
          if [ -n "$open" ]; then
            echo "tier $tier is not closed under depends_on: $open" >&2
            exit 1
          fi

          if [ -n "$down" ] && ! jq -e --slurpfile spec ${tiersJson} --arg tier "$tier" --arg down "$down" \
            '$spec[0].tiers[$tier] | index($down)' ${stateDir}/homelab.json > /dev/null; then
            echo "homelab.smoke.down=$down is not in tier $tier" >&2
            exit 1
          fi

          jq --slurpfile spec ${tiersJson} --arg tier "$tier" --arg down "$down" '
            ($spec[0].tiers[$tier] - [$down]) as $members
            | {services: ([.services | keys[] | select(. as $name | $members | index($name) | not)]
                | map({key: ., value: {scale: 0}}) | from_entries)}' ${stateDir}/homelab.json > ${tierFile}
        '';
      };

      smokeScript = pkgs.writeShellApplication {
        name = "homelab-smoke";
        runtimeInputs = [
          docker
          pkgs.jq
          pkgs.curl
          pkgs.gawk
          pkgs.gnugrep
          pkgs.coreutils
          pkgs.systemd
        ];
        text = ''
          out=${results}
          summary=$out/summary.tsv
          mkdir -p "$out"
          : > "$summary"

          record() {
            printf '%s\n' "$*" | tr ' ' '\t' >> "$summary"
          }

          tier=$(cat ${stateDir}/tier)
          down=$(cat ${stateDir}/down)
          downLabel=none
          [ -z "$down" ] || downLabel=$down
          record tier "$tier"
          record down "$downLabel"
          started=$(date +%s)
          deadline=$((started + ${toString healthWindowSeconds}))
          failures=0

          fail() {
            failures=$((failures + 1))
            record failure "$@"
          }

          for unit in homelab-smoke-tier homelab-vm-checkout homelab-compose; do
            state=$(systemctl show -p ActiveState --value "$unit")
            record unit "$unit" "$state"
            [ "$state" = active ] || fail unit "$unit" "$state"
          done

          declare -a expected=()
          if [ -s ${stateDir}/homelab.json ]; then
            while read -r service; do
              expected+=("homelab/$service")
            done < <(jq -r --arg tier "$tier" '.tiers[$tier][] as $name | select(.expectedFailures | index($name) | not) | $name' ${tiersJson})
          fi

          declare -A tokens=()
          if [ -s ${stateDir}/homelab.json ]; then
            while read -r token service; do
              tokens[$token]="homelab/$service"
            done < <(jq -r '.services | to_entries[] | .key as $name
              | ([$name, .value.container_name] + [(.value.networks // {}) | to_entries[] | (.value // {}).aliases // [] | .[]])
              | map(select(. != null)) | unique[] | "\(.) \($name)"' ${stateDir}/homelab.json)
          fi

          if [ "$tier" = ${openseoTier} ]; then
            state=$(systemctl show -p ActiveState --value openseo-compose)
            record unit openseo-compose "$state"
            [ "$state" = active ] || fail unit openseo-compose "$state"
            ${openseoCompose} config --format json > ${stateDir}/openseo.json
            while read -r service; do
              expected+=("openseo/$service")
            done < <(jq -r '.services | keys[]' ${stateDir}/openseo.json)
            while read -r token service; do
              tokens[$token]="openseo/$service"
            done < <(jq -r '.services | to_entries[] | .key as $name
              | ([$name] + [(.value.networks // {}) | to_entries[] | (.value // {}).aliases // [] | .[]])
              | map(select(. != null)) | unique[] | "\(.) \($name)"' ${stateDir}/openseo.json)
          fi

          domain=$(grep '^CADDY_DOMAIN=' ${checkout}/homelab.env | cut -d= -f2)
          declare -A routes=()
          while read -r name upstream; do
            case "$upstream" in
              *HOST_MACHINE_HOSTNAME*) target=homelab/adguard ;;
              *) target=''${tokens[''${upstream%%:*}]-unknown} ;;
            esac
            for member in "''${expected[@]}"; do
              if [ "$member" = "$target" ]; then
                routes["$name.$domain"]=$target
              fi
            done
          done < <(awk '
            /^[[:space:]]*@[A-Za-z0-9_-]+[[:space:]]+host[[:space:]]/ { host = $3; sub(/\.\{env\.DOMAIN\}$/, "", host) }
            /^[[:space:]]*reverse_proxy[[:space:]]/ && host != "" { print host, $2; host = "" }
          ' ${vmCaddyfile})

          declare -A status=() since=() signature=() oomed=() routeCode=() routeOk=()
          for member in "''${expected[@]}"; do
            status[$member]=missing
            since[$member]=0
            signature[$member]=none
            oomed[$member]=false
          done
          for host in "''${!routes[@]}"; do
            routeCode[$host]=none
            routeOk[$host]=false
          done

          guestPeak=0
          containerId() {
            docker ps -aq --no-trunc \
              --filter "label=com.docker.compose.project=''${1%%/*}" \
              --filter "label=com.docker.compose.service=''${1#*/}" | head -n1 || true
          }

          while :; do
            now=$(date +%s)
            used=$(awk '/^MemTotal:/ { total = $2 } /^MemAvailable:/ { available = $2 } END { print int((total - available) / 1024) }' /proc/meminfo)
            [ "$used" -gt "$guestPeak" ] && guestPeak=$used

            pending=0
            for member in "''${expected[@]}"; do
              id=$(containerId "$member")
              if [ -z "$id" ]; then
                status[$member]=missing
                pending=$((pending + 1))
                continue
              fi
              if ! read -r state health restarts code oom policy < <(docker inspect --format \
                '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.RestartCount}} {{.State.ExitCode}} {{.State.OOMKilled}} {{.HostConfig.RestartPolicy.Name}}' "$id"); then
                status[$member]=missing
                pending=$((pending + 1))
                continue
              fi
              [ "$oom" = true ] && oomed[$member]=true
              if [ "''${signature[$member]}" != "$state:$restarts" ]; then
                signature[$member]="$state:$restarts"
                since[$member]=$now
              fi
              if [ "$health" = healthy ]; then
                status[$member]=healthy
              elif [ "$health" = none ] && [ "$state" = running ] && [ $((now - since[$member])) -ge ${toString stableSeconds} ]; then
                status[$member]=running
              elif [ "$state" = exited ] && [ "$code" = 0 ] && { [ "$policy" = no ] || [ "$policy" = on-failure ]; }; then
                status[$member]=completed
              else
                status[$member]="waiting:$state:health=$health:restarts=$restarts:exit=$code"
                pending=$((pending + 1))
              fi
            done

            for host in "''${!routes[@]}"; do
              [ "''${routeOk[$host]}" = true ] && continue
              code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$host:443:127.0.0.1" "https://$host/" || true)
              routeCode[$host]=$code
              case "$code" in
                2??|3??) routeOk[$host]=true ;;
                *) pending=$((pending + 1)) ;;
              esac
            done

            if [ "$pending" -eq 0 ] || [ "$now" -ge "$deadline" ]; then
              break
            fi
            sleep 5
          done

          record settle_seconds "$(( $(date +%s) - started ))"

          for member in "''${expected[@]}"; do
            id=$(containerId "$member")
            peak=none
            if [ -n "$id" ] && [ -r "/sys/fs/cgroup/system.slice/docker-$id.scope/memory.peak" ]; then
              peak=$(( $(cat "/sys/fs/cgroup/system.slice/docker-$id.scope/memory.peak") / 1048576 ))
            fi
            record container "$member" "''${status[$member]}" "oom=''${oomed[$member]}" "peak_mib=$peak"
            case "''${status[$member]}" in
              healthy|running|completed) ;;
              *) fail container "$member" "''${status[$member]}" ;;
            esac
            [ "''${oomed[$member]}" = false ] || fail oom "$member"
          done

          for host in "''${!routes[@]}"; do
            record route "$host" "''${routes[$host]}" "''${routeCode[$host]}"
            [ "''${routeOk[$host]}" = true ] || fail route "$host" "''${routeCode[$host]}"
          done

          kernelOom=$(journalctl -k -o cat | grep -ciE 'out of memory|oom-kill|killed process' || true)
          record kernel_oom "$kernelOom"
          [ "$kernelOom" -eq 0 ] || fail kernel_oom "$kernelOom"

          for member in ${lib.concatStringsSep " " expectedFailures}; do
            id=$(containerId "homelab/$member")
            [ -n "$id" ] && record expected_failure "homelab/$member" "$(docker inspect --format '{{.State.Status}}:restarts={{.RestartCount}}' "$id")"
          done

          record guest_peak_mib "$guestPeak"
          record guest_mem_total_mib "$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)"
          docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}' > "$out/docker-stats.tsv" || true
          docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' > "$out/images.tsv" || true
          docker ps -a --format '{{.Names}}\t{{.Status}}' > "$out/docker-ps.tsv" || true
          journalctl -b -u homelab-smoke-tier -u homelab-vm-checkout -u homelab-compose -u openseo-compose -o short-monotonic > "$out/units.log" || true
          for member in "''${expected[@]}"; do
            case "''${status[$member]}" in
              healthy|running|completed) ;;
              *)
                id=$(containerId "$member")
                [ -n "$id" ] && docker logs --tail 80 "$id" > "$out/logs-''${member/\//-}.log" 2>&1 || true
                ;;
            esac
          done

          if [ "$failures" -eq 0 ]; then
            record verdict pass
          else
            record verdict fail
          fi
          sync
          systemctl poweroff --no-block
        '';
      };
    in
    {
      imports = [ ../../secrets/test-module.nix ];

      virtualisation = {
        memorySize = 6144;
        cores = 4;
        diskSize = 40960;
        graphics = false;
        writableStoreUseTmpfs = false;
        emptyDiskImages = [ (emptyDisk "disk1") (emptyDisk "disk2") ];
        fileSystems = {
          "/mnt/disk1" = lib.mkForce (dataDisk "disk1");
          "/mnt/disk2" = lib.mkForce (dataDisk "disk2");
        };
      };

      homelab = {
        gpu.enable = false;
        egress.enable = false;
        lan.interface = "eth0";
        secrets.sopsFile = lib.mkForce ../../secrets/vm.yaml;
        compose.extraFiles.homelab = [ nogpuOverride caddyOverride tierFile ];
      };

      systemd.services = {
        windows-compose.wantedBy = lib.mkForce [ ];

        openseo-compose.unitConfig.ConditionKernelCommandLine = [ "homelab.smoke=${openseoTier}" ];

        homelab-vm-checkout = {
          description = "Copy the flake source to the homelab checkout";
          requiredBy = [ "homelab-compose.service" ];
          before = [ "homelab-compose.service" "homelab-smoke-tier.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = lib.getExe checkoutScript;
          };
        };

        homelab-smoke-tier = {
          description = "Scale every service outside the smoke tier to zero";
          requiredBy = [ "homelab-compose.service" ];
          before = [ "homelab-compose.service" ];
          after = [ "homelab-vm-checkout.service" ];
          requires = [ "homelab-vm-checkout.service" ];
          environment = composeEnvironment;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = lib.getExe tierScript;
          };
        };

        homelab-smoke = {
          description = "Check the smoke tier's containers and Caddy routes, then power off";
          wantedBy = [ "multi-user.target" ];
          after = [ "homelab-compose.service" "openseo-compose.service" ];
          environment = composeEnvironment;
          unitConfig.ConditionKernelCommandLine = [ "homelab.smoke" ];
          serviceConfig = {
            Type = "oneshot";
            TimeoutStartSec = "infinity";
            ExecStart = lib.getExe smokeScript;
          };
        };
      };
    };
}
