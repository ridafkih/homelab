{ pkgs, self, lib }:
let
  backupModulePath = self + "/modules/backup.nix";
  excludesPath = self + "/modules/backup-excludes.txt";
  backupModule =
    if builtins.pathExists backupModulePath then backupModulePath else throw "modules/backup.nix is missing";

  sopsModule = self.inputs.sops-nix.nixosModules.sops;
  secretsModule = self + "/modules/secrets.nix";
  storageModule = self + "/modules/storage.nix";
  testModule = self + "/secrets/test-module.nix";

  disk1Repo = "/mnt/disk2/backup/restic";
  disk2Repo = "/mnt/disk1/backup/restic";

  systemPaths = [
    "/etc"
    "/root"
    "/home/rida"
    "/var/lib/tailscale"
    "/var/lib/docker/volumes/homelab_grafana-funnel"
    "/var/lib/docker/volumes/homelab_signoz-sqlite"
    "/var/lib/docker/volumes/homelab_grafana"
    "/var/lib/docker/volumes/grafana_grafana-data"
    "/var/backups/homelab-db"
  ];

  expectedExcludes = ''
    /home/rida/.cache
    /home/rida/.npm
    /home/rida/.nvm
    /home/rida/go
    /home/rida/.bun/install
    /home/rida/.mozilla
    /home/rida/.local/share
    **/node_modules
    /data/windows
    /home/rida/homelab/.data/llama-cpp
    /home/rida/homelab/.data/vllm
    /home/rida/homelab/.data/jellyfin/cache
    /home/rida/homelab/.data/jellyfin/config/metadata
    /home/rida/homelab/.data/jellyfin/config/data/attachments
    /home/rida/homelab/.data/jellyfin/config/data/subtitles
    /home/rida/homelab/.data/jellyfin/config/log
    /home/rida/homelab/.data/open-webui/app/backend/data/cache
    /home/rida/homelab/.data/adguardhome/work/data/querylog.json*
    /home/rida/homelab/.data/*/MediaCover
    /home/rida/homelab/.data/*/logs
    /home/rida/homelab/.data/*/Sentry
    /home/rida/homelab/.data/*/logs.db*
    /mnt/disk1/seafile/seafile/logs
    /mnt/disk2/seafile/seafile/logs
    /root/.cache
  '';

  archFiles = [
    "host/usr/local/sbin/homelab-backup"
    "host/etc/homelab-backup/excludes"
    "host/etc/systemd/system/homelab-backup.service"
    "host/etc/systemd/system/homelab-backup.timer"
  ];

  host = self.nixosConfigurations.homelab.extendModules { modules = [ testModule ]; };
  cfg = host.config;
  renamed = host.extendModules { modules = [ { networking.hostName = lib.mkForce "elsewhere"; } ]; };

  evaluates = value: (builtins.tryEval (builtins.deepSeq value true)).success;
  holds = value: let result = builtins.tryEval value; in result.success && result.value == true;
  includesAll = wanted: present: builtins.all (item: builtins.elem item present) wanted;
  listOf = value: if builtins.isList value then value else lib.splitString " " (toString value);
  sorted = list: lib.sort lib.lessThan list;

  failingAssertions = config:
    builtins.length (
      builtins.filter (entry: let result = builtins.tryEval entry.assertion; in result.success && result.value == false)
        config.assertions
    );

  hashChar = builtins.fromJSON ''"\u0023"'';
  shellFallback = ":" + "-";
  sourceOf = name: let path = self + "/${name}"; in if builtins.pathExists path then builtins.readFile path else "";
  ownedNixSources = [ "modules/backup.nix" "tests/backup.nix" ];
  offsiteSchemes = [ "s3:" "b2:" "rclone:" "sftp:" "rest:" "azure:" "gs:" "swift:" ];
  mentionsOffsite = text: lib.any (scheme: lib.hasInfix scheme text) offsiteSchemes;

  jobs = cfg.services.restic.backups;
  job = name: jobs.${name} or (throw "restic job ${name} is missing");
  service = name: cfg.systemd.services."restic-backups-${name}" or { };

  tokens = opts:
    builtins.filter (token: token != "") (
      lib.splitString " " (builtins.replaceStrings [ "=" ] [ " " ] (lib.concatStringsSep " " opts))
    );
  pairsOf = opts:
    let
      list = tokens opts;
      count = builtins.length list / 2;
    in
    if lib.mod (builtins.length list) 2 != 0 then
      throw "odd option list"
    else
      builtins.genList (index: "${builtins.elemAt list (2 * index)} ${builtins.elemAt list (2 * index + 1)}") count;

  joinedArgs = name: lib.concatStringsSep " " ((job name).extraBackupArgs or [ ]);
  excludeFileArgs = name:
    builtins.filter (arg: lib.hasPrefix "--exclude-file=" arg) (lib.splitString " " (joinedArgs name));
  excludeFileReadable = name:
    let args = excludeFileArgs name; in
    builtins.length args == 1
    && builtins.unsafeDiscardStringContext (builtins.head args) == "--exclude-file=${builtins.unsafeDiscardStringContext "${../modules/backup-excludes.txt}"}"
    && builtins.readFile ../modules/backup-excludes.txt == expectedExcludes;

  unitSettled = name:
    includesAll [ "/mnt/disk1" "/mnt/disk2" ] (listOf ((service name).unitConfig.RequiresMountsFor or [ ]))
    && builtins.elem "docker.service" ((service name).after or [ ])
    && builtins.elem "docker.service" ((service name).requires or [ ])
    && ((service name).serviceConfig.Nice or null) == 10
    && ((service name).serviceConfig.IOSchedulingClass or null) == "idle";

  sharedJobSettings = name:
    (job name).initialize == false
    && (job name).passwordFile == cfg.homelab.secrets.resticPasswordFile
    && lib.hasInfix "--exclude-caches" (joinedArgs name)
    && lib.hasInfix "--tag homelab" (joinedArgs name)
    && excludeFileReadable name
    && sorted (pairsOf (job name).pruneOpts) == sorted [
      "--tag homelab"
      "--group-by host,tags"
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 6"
    ]
    && builtins.elem "--read-data-subset=5%" (job name).checkOpts
    && (job name).runCheck == true
    && (job name).createWrapper == true;

  expectations = {
    backupModuleExists = builtins.pathExists backupModulePath;
    excludesFileExists = builtins.pathExists excludesPath;
    excludesMatchArchWithWindowsMoved = builtins.pathExists excludesPath && builtins.readFile excludesPath == expectedExcludes;
    archBackupFilesDeleted = builtins.all (name: !(builtins.pathExists (self + "/${name}"))) archFiles;

    exactlyTwoJobs = sorted (lib.attrNames jobs) == [ "disk1" "disk2" ];
    disk1WritesToDisk2 = (job "disk1").repository == disk1Repo;
    disk2WritesToDisk1 = (job "disk2").repository == disk2Repo;
    disk1Paths = sorted (job "disk1").paths == sorted (systemPaths ++ [ "/mnt/disk1/seafile" ]);
    disk2Paths = sorted (job "disk2").paths == sorted (systemPaths ++ [ "/mnt/disk2/seafile" ]);
    noDataInPaths = !(lib.any (path: path == "/data" || lib.hasPrefix "/data/" path) ((job "disk1").paths ++ (job "disk2").paths));
    noDynamicPaths = (job "disk1").dynamicFilesFrom == null && (job "disk2").dynamicFilesFrom == null;
    disk1Settings = sharedJobSettings "disk1";
    disk2Settings = sharedJobSettings "disk2";

    disk1Timer =
      let timer = (job "disk1").timerConfig; in
      timer != null && (timer.OnCalendar or null) == "*-*-* 03:30" && (timer.Persistent or null) == true;
    disk2HasNoTimer = (job "disk2").timerConfig == null && !(cfg.systemd.timers ? restic-backups-disk2);
    timerUnitExists = cfg.systemd.timers ? restic-backups-disk1;

    dumpsOnlyInDisk1 = (job "disk1").backupPrepareCommand != null && (job "disk2").backupPrepareCommand == null;
    disk1WantsDisk2 = builtins.elem "restic-backups-disk2.service" ((service "disk1").wants or [ ]);
    disk2AfterDisk1 = builtins.elem "restic-backups-disk1.service" ((service "disk2").after or [ ]);
    disk1NotAfterDisk2 = !(builtins.elem "restic-backups-disk2.service" ((service "disk1").after or [ ]));
    disk2NotRequiringDisk1 =
      !(builtins.elem "restic-backups-disk1.service" ((service "disk2").requires or [ ]))
      && !(builtins.elem "restic-backups-disk1.service" ((service "disk2").bindsTo or [ ]));
    disk1Unit = unitSettled "disk1";
    disk2Unit = unitSettled "disk2";

    renamedHostFailsEval = failingAssertions renamed.config > failingAssertions cfg;

    noOffsiteRepository =
      !(lib.any (backup: mentionsOffsite backup.repository) (lib.attrValues jobs))
      && !(mentionsOffsite (sourceOf "modules/backup.nix"))
      && !(mentionsOffsite (sourceOf "modules/backup-excludes.txt"));
    noRepositoryFile = (job "disk1").repositoryFile == null && (job "disk2").repositoryFile == null;

    authentikContainerName = lib.hasInfix "container_name: authentik-postgresql" (sourceOf "apps/authentik/compose.yaml");
    seafileContainerName = lib.hasInfix "container_name: seafile-db" (sourceOf "apps/seafile/compose.yaml");
    openseoProjectName = lib.hasPrefix "name: openseo\n" (sourceOf "apps/openseo/compose.yaml");

    noComments = builtins.all (name: !(lib.hasInfix hashChar (sourceOf name))) ownedNixSources;
    noShellFallbacks = builtins.all (name: !(lib.hasInfix shellFallback (sourceOf name))) ownedNixSources;
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !(evaluates passed) || !(holds passed)) expectations);

  prepareText = pkgs.writeText "backup-prepare-command" (let command = (jobs.disk1 or { }).backupPrepareCommand or null; in if command == null then "" else command);
  prepareProbe = pkgs.runCommand "backup-prepare-probe" { } ''
    scripts=$(grep -oE '/nix/store/[a-z0-9]{32}-[^/ "]+' ${prepareText} | sort -u)
    test -n "$scripts"
    all=$(for path in $scripts; do if [ -d "$path" ]; then cat "$path"/bin/* 2>/dev/null; else cat "$path"; fi; done)
    for needle in authentik-postgresql seafile-db pg_dumpall mariadb-dump MYSQL_ROOT_PASSWORD manifest.json /var/backups/homelab-db; do
      printf '%s' "$all" | grep -qF -- "$needle" || { echo "prepare command lacks $needle"; exit 1; }
    done
    printf '%s' "$all" | grep -qE -- '-p openseo|--project-name openseo|--project-name=openseo' || { echo "prepare command lacks the openseo project"; exit 1; }
    if printf '%s' "$all" | grep -qiE 'keeper|/home/rida/homelab/openseo'; then echo "prepare command still names Keeper or the old openseo dir"; exit 1; fi
    echo ok > $out
  '';

  stubDumps = pkgs.writeShellScript "stub-homelab-db-dumps" ''
    set -eu
    if [ -e /run/backup-test/fail-dumps ]; then
      exit 1
    fi
    install -d -m 0700 /var/backups/homelab-db
    echo stub > /var/backups/homelab-db/stub.sql
  '';

  dataDisk = serial: {
    device = "/dev/disk/by-id/virtio-${serial}";
    fsType = "ext4";
    autoFormat = true;
    options = [ "nofail" "noatime" ];
  };

  vm = pkgs.testers.runNixOSTest {
    name = "backup-vm";
    nodes.machine = { lib, ... }: {
      imports = [ sopsModule self.nixosModules.options secretsModule testModule storageModule backupModule ];
      networking.hostName = "homelab";
      virtualisation.memorySize = 2048;
      virtualisation.docker.enable = true;
      virtualisation.emptyDiskImages = [
        {
          size = 8192;
          driveConfig.deviceExtraOpts.serial = "disk1";
        }
        {
          size = 8192;
          driveConfig.deviceExtraOpts.serial = "disk2";
        }
      ];
      virtualisation.fileSystems."/mnt/disk1" = lib.mkForce (dataDisk "disk1");
      virtualisation.fileSystems."/mnt/disk2" = lib.mkForce (dataDisk "disk2");
      services.restic.backups.disk1.backupPrepareCommand = lib.mkForce "${stubDumps}";
      environment.systemPackages = [ pkgs.restic pkgs.jq ];
    };
    testScript = { nodes, ... }: ''
      import json

      password = "${nodes.machine.homelab.secrets.resticPasswordFile}"
      repos = {"disk1": "${disk1Repo}", "disk2": "${disk2Repo}"}
      system_paths = json.loads('${builtins.toJSON systemPaths}')

      def restic(repo, args):
          return machine.succeed(f"restic -r {repo} --password-file {password} {args}")

      def show(unit, prop):
          return machine.succeed(f"systemctl show -p {prop} --value {unit}").strip()

      def snapshots(repo):
          return json.loads(restic(repo, "snapshots --json"))

      def listing(repo):
          return restic(repo, "ls latest").split("\n")

      def run_chain():
          machine.execute("systemctl reset-failed restic-backups-disk1.service restic-backups-disk2.service")
          before = show("restic-backups-disk2.service", "InactiveExitTimestampMonotonic")
          machine.execute("systemctl start restic-backups-disk1.service")
          machine.wait_until_succeeds("test \"$(systemctl show -p ActiveState --value restic-backups-disk1.service)\" != activating", timeout=600)
          machine.wait_until_succeeds(f"test \"$(systemctl show -p InactiveExitTimestampMonotonic --value restic-backups-disk2.service)\" != {before}", timeout=600)
          machine.wait_until_succeeds("test \"$(systemctl show -p ActiveState --value restic-backups-disk2.service)\" != activating", timeout=600)
          disk1_done = int(show("restic-backups-disk1.service", "InactiveEnterTimestampMonotonic"))
          disk2_start = int(show("restic-backups-disk2.service", "InactiveExitTimestampMonotonic"))
          assert disk2_start >= disk1_done, f"disk2 started at {disk2_start} before disk1 finished at {disk1_done}"
          return show("restic-backups-disk1.service", "Result"), show("restic-backups-disk2.service", "Result")

      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("mnt-disk1.mount")
      machine.wait_for_unit("mnt-disk2.mount")
      machine.wait_for_unit("data.mount")
      machine.wait_for_unit("docker.service")

      with subtest("timer: only disk1, nightly at 03:30, persistent"):
          calendar = show("restic-backups-disk1.timer", "TimersCalendar")
          assert "OnCalendar=*-*-* 03:30:00" in calendar, calendar
          assert show("restic-backups-disk1.timer", "Persistent") == "yes"
          machine.succeed("systemctl list-timers --all | grep -q restic-backups-disk1.timer")
          assert show("restic-backups-disk2.timer", "LoadState") == "not-found"

      with subtest("units: mounts, docker, priority, chain"):
          for name in ["disk1", "disk2"]:
              unit = f"restic-backups-{name}.service"
              requires = show(unit, "RequiresMountsFor").split()
              assert "/mnt/disk1" in requires and "/mnt/disk2" in requires, requires
              assert "docker.service" in show(unit, "After").split()
              assert "docker.service" in show(unit, "Requires").split()
              assert show(unit, "Nice") == "10"
              assert show(unit, "IOSchedulingClass") in ["idle", "3"], show(unit, "IOSchedulingClass")
          assert "restic-backups-disk2.service" in show("restic-backups-disk1.service", "Wants").split()
          assert "restic-backups-disk1.service" in show("restic-backups-disk2.service", "After").split()
          machine.succeed("command -v restic-disk1")
          machine.succeed("command -v restic-disk2")

      with subtest("fixtures"):
          machine.succeed(
              "mkdir -p /data/media /data/windows "
              "/home/rida/proj/node_modules /home/rida/.cache /home/rida/tagged "
              "/home/rida/homelab/.data/llama-cpp /home/rida/homelab/.data/jellyfin/cache "
              "/home/rida/homelab/.data/sonarr/logs /home/rida/homelab/.data/authentik/media "
              "/root/.cache /var/lib/tailscale "
              "/mnt/disk1/seafile/seafile-data /mnt/disk2/seafile/seafile-data "
              "/mnt/disk1/seafile/seafile/logs /mnt/disk2/seafile/seafile/logs"
          )
          for path in system_paths:
              machine.succeed(f"mkdir -p {path}")
          for volume in ["homelab_grafana-funnel", "homelab_signoz-sqlite", "homelab_grafana", "grafana_grafana-data"]:
              machine.succeed(f"mkdir -p /var/lib/docker/volumes/{volume}/_data && echo {volume} > /var/lib/docker/volumes/{volume}/_data/keep-{volume}")
          machine.succeed("echo movie > /data/media/movie-never-backed-up.mkv")
          machine.succeed("echo win > /data/windows/windows-never-backed-up.img")
          machine.succeed("echo etc > /etc/keep-etc-probe")
          machine.succeed("echo notes > /home/rida/keep-notes.txt")
          machine.succeed("echo auth > /home/rida/homelab/.data/authentik/media/keep-authentik")
          machine.succeed("echo root > /root/keep-root")
          machine.succeed("echo ts > /var/lib/tailscale/keep-tailscale")
          machine.succeed("echo one > /mnt/disk1/seafile/seafile-data/keep-seafile-disk1")
          machine.succeed("echo two > /mnt/disk2/seafile/seafile-data/keep-seafile-disk2")
          machine.succeed("echo x > /home/rida/proj/node_modules/excluded-node-modules")
          machine.succeed("echo x > /home/rida/.cache/excluded-home-cache")
          machine.succeed("echo x > /home/rida/homelab/.data/llama-cpp/excluded-llama")
          machine.succeed("echo x > /home/rida/homelab/.data/jellyfin/cache/excluded-jellyfin-cache")
          machine.succeed("echo x > /home/rida/homelab/.data/sonarr/logs/excluded-arr-logs")
          machine.succeed("echo x > /root/.cache/excluded-root-cache")
          machine.succeed("echo x > /mnt/disk1/seafile/seafile/logs/excluded-seafile-log-disk1")
          machine.succeed("echo x > /mnt/disk2/seafile/seafile/logs/excluded-seafile-log-disk2")
          machine.succeed("printf 'Signature: 8a477f597d28d172789f06886806bc55' > /home/rida/tagged/CACHEDIR.TAG")
          machine.succeed("echo x > /home/rida/tagged/excluded-cachedir-tag")
          machine.succeed("sync")

      with subtest("initialize is off: a missing repository fails loudly"):
          result_disk1, result_disk2 = run_chain()
          assert result_disk1 != "success", result_disk1
          assert result_disk2 != "success", result_disk2
          for repo in repos.values():
              machine.fail(f"test -e {repo}/config")

      for repo in repos.values():
          machine.succeed(f"mkdir -p {repo}")
          restic(repo, "init")

      with subtest("the chain runs both jobs in order"):
          result_disk1, result_disk2 = run_chain()
          assert result_disk1 == "success", result_disk1
          assert result_disk2 == "success", result_disk2

      with subtest("snapshots carry host homelab and tag homelab, and check passes"):
          for name, repo in repos.items():
              snaps = snapshots(repo)
              assert len(snaps) == 1, f"{name}: {snaps}"
              assert snaps[0]["hostname"] == "homelab", snaps[0]
              assert "homelab" in snaps[0].get("tags", []), snaps[0]
              restic(repo, "check")

      with subtest("selective contents"):
          never = [
              "movie-never-backed-up.mkv",
              "windows-never-backed-up.img",
              "excluded-node-modules",
              "excluded-home-cache",
              "excluded-llama",
              "excluded-jellyfin-cache",
              "excluded-arr-logs",
              "excluded-root-cache",
              "excluded-seafile-log-disk1",
              "excluded-seafile-log-disk2",
              "excluded-cachedir-tag",
          ]
          always = [
              "/etc/keep-etc-probe",
              "/home/rida/keep-notes.txt",
              "/home/rida/homelab/.data/authentik/media/keep-authentik",
              "/root/keep-root",
              "/var/lib/tailscale/keep-tailscale",
              "/var/backups/homelab-db/stub.sql",
              "/var/lib/docker/volumes/homelab_grafana-funnel/_data/keep-homelab_grafana-funnel",
              "/var/lib/docker/volumes/homelab_signoz-sqlite/_data/keep-homelab_signoz-sqlite",
              "/var/lib/docker/volumes/homelab_grafana/_data/keep-homelab_grafana",
              "/var/lib/docker/volumes/grafana_grafana-data/_data/keep-grafana_grafana-data",
          ]
          own_half = {
              "disk1": "/mnt/disk1/seafile/seafile-data/keep-seafile-disk1",
              "disk2": "/mnt/disk2/seafile/seafile-data/keep-seafile-disk2",
          }
          for name, repo in repos.items():
              paths = listing(repo)
              for path in always:
                  assert path in paths, f"{name}: {path} missing"
              assert own_half[name] in paths, f"{name}: {own_half[name]} missing"
              other = own_half["disk2" if name == "disk1" else "disk1"]
              assert other not in paths, f"{name}: holds {other}"
              for path in paths:
                  assert path != "/data" and not path.startswith("/data/"), f"{name}: {path}"
                  assert "/media/" not in path or "/authentik/media" in path, f"{name}: {path}"
                  for needle in never:
                      assert needle not in path, f"{name}: {path}"

      with subtest("a failed dump still lets disk2 run"):
          machine.succeed("mkdir -p /run/backup-test && touch /run/backup-test/fail-dumps")
          result_disk1, result_disk2 = run_chain()
          assert result_disk1 != "success", result_disk1
          assert result_disk2 == "success", result_disk2
          assert len(snapshots(repos["disk1"])) == 1
          assert len(snapshots(repos["disk2"])) == 2
    '';
  };
in
pkgs.runCommand "backup" {
  vm = if failed == [ ] then vm else throw "homelab backup expectations failed: ${lib.concatStringsSep ", " failed}";
  prepare = prepareProbe;
} ''
  echo ok > $out
''
