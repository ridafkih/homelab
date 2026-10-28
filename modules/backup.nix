{ config, lib, pkgs, ... }:
let
  dumpDir = "/var/backups/homelab-db";

  systemPaths = [
    "/etc"
    "/root"
    "/home/rida"
    "/var/lib/tailscale"
    "/var/lib/docker/volumes/homelab_grafana-funnel"
    "/var/lib/docker/volumes/homelab_signoz-sqlite"
    "/var/lib/docker/volumes/homelab_grafana"
    "/var/lib/docker/volumes/grafana_grafana-data"
    dumpDir
  ];

  dataMounts = [ "/mnt/disk1" "/mnt/disk2" ];

  databaseDumps = pkgs.writeShellApplication {
    name = "homelab-db-dumps";
    runtimeInputs = [ config.virtualisation.docker.package pkgs.coreutils pkgs.gnugrep ];
    text = ''
      umask 077

      readonly dump_dir=${dumpDir}

      fail() {
        echo "homelab-db-dumps: $*" >&2
        exit 1
      }

      dump_postgres() {
        local container=$1 target="$dump_dir/$1.sql"
        docker exec "$container" sh -c 'exec pg_dumpall --clean --if-exists -U "$POSTGRES_USER"' > "$target.partial"
        tail -n 5 "$target.partial" | grep -q "PostgreSQL database cluster dump complete" || fail "$container dump incomplete"
        mv "$target.partial" "$target"
      }

      dump_mariadb() {
        local container=$1 target="$dump_dir/$1.sql"
        docker exec "$container" sh -c 'exec mariadb-dump -uroot -p"$MYSQL_ROOT_PASSWORD" --all-databases --single-transaction --routines --events --triggers' > "$target.partial"
        tail -n 1 "$target.partial" | grep -q "Dump completed" || fail "$container dump incomplete"
        mv "$target.partial" "$target"
      }

      openseo_compose() {
        docker compose -p openseo "$@"
      }

      archive_openseo_volume() {
        local image=$1 container=$2 path=$3 target=$4
        docker run --rm --network none -u 0 --volumes-from "$container:ro" --entrypoint tar "$image" \
          -czf - -C "$path" . > "$target"
      }

      dump_openseo() {
        local target="$dump_dir/openseo" runtime storage image status=0
        local -a running
        runtime=$(openseo_compose ps -aq runtime)
        storage=$(openseo_compose ps -aq storage)
        [[ -n "$runtime" && -n "$storage" ]] || fail "openseo is not deployed"
        image=$(docker inspect --format '{{.Image}}' "$runtime")
        mapfile -t running < <(openseo_compose ps --services --status running | grep -xE 'web|runtime|crawl-gateway|storage' || true)
        rm -rf "$target.partial"
        install -d -m 0700 "$target.partial"
        openseo_compose stop web crawl-gateway runtime storage
        archive_openseo_volume "$image" "$storage" /data "$target.partial/storage.tar.gz" || status=$?
        ((status)) || archive_openseo_volume "$image" "$runtime" /config "$target.partial/config.tar.gz" || status=$?
        [[ -z "''${running[*]}" ]] || openseo_compose start "''${running[@]}"
        ((status == 0)) || fail "openseo volume archive failed"
        printf '{"format":1,"celld":"0.5.1","image":"%s","createdAt":"%s","files":{"storage.tar.gz":"%s","config.tar.gz":"%s"}}\n' \
          "$image" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
          "$(sha256sum "$target.partial/storage.tar.gz" | cut -d' ' -f1)" \
          "$(sha256sum "$target.partial/config.tar.gz" | cut -d' ' -f1)" > "$target.partial/manifest.json"
        rm -rf "$target"
        mv "$target.partial" "$target"
      }

      install -d -m 0700 "$dump_dir"
      dump_postgres authentik-postgresql
      dump_mariadb seafile-db
      dump_openseo
    '';
  };

  job = seafileHalf: repository: {
    inherit repository;
    paths = systemPaths ++ [ seafileHalf ];
    initialize = false;
    passwordFile = config.homelab.secrets.resticPasswordFile;
    extraBackupArgs = [
      "--exclude-file=${./backup-excludes.txt}"
      "--exclude-caches"
      "--tag homelab"
    ];
    pruneOpts = [
      "--tag homelab"
      "--group-by host,tags"
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 6"
    ];
    checkOpts = [ "--read-data-subset=5%" ];
    runCheck = true;
    createWrapper = true;
  };

  unit = {
    unitConfig.RequiresMountsFor = dataMounts;
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    serviceConfig = {
      Nice = 10;
      IOSchedulingClass = "idle";
    };
  };
in
{
  services.restic.backups = {
    disk1 = job "/mnt/disk1/seafile" "/mnt/disk2/backup/restic" // {
      backupPrepareCommand = lib.getExe databaseDumps;
      timerConfig = {
        OnCalendar = "*-*-* 03:30";
        Persistent = true;
        RandomizedDelaySec = "10m";
      };
    };
    disk2 = job "/mnt/disk2/seafile" "/mnt/disk1/backup/restic" // {
      timerConfig = null;
    };
  };

  systemd.services = {
    restic-backups-disk1 = lib.recursiveUpdate unit {
      wants = [ "restic-backups-disk2.service" ];
    };
    restic-backups-disk2 = lib.recursiveUpdate unit {
      after = unit.after ++ [ "restic-backups-disk1.service" ];
    };
  };

  assertions = [
    {
      assertion = config.networking.hostName == "homelab";
      message = "networking.hostName must stay homelab: the restic snapshots and their prune grouping (--group-by host,tags) are keyed on it";
    }
  ];
}
