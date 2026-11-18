{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.minecraft;

  players = {
    eilixirs = "9cba2143-7e02-41b6-b609-03a453218dc8";
    GetRidaHim = "8cc4eb44-65fe-4b22-b71d-4c2bcc8473c0";
  };

  paperVersion = "26.3";
  paperBuild = 253;
  paperHash = "f9df8e19f4bdee97dbded48095391ea69c64342a4e19624db4f5e0d0136dfe0b";

  paper = (pkgs.callPackage "${pkgs.path}/pkgs/games/papermc/derivation.nix" {
    jre = pkgs.jdk25_headless;
    version = "${paperVersion}-${toString paperBuild}";
    hash = "sha256:${paperHash}";
  }).overrideAttrs {
    src = pkgs.fetchurl {
      url = "https://fill-data.papermc.io/v1/objects/${paperHash}/paper-${paperVersion}-${toString paperBuild}.jar";
      sha256 = paperHash;
    };
  };

  paperFlags = [
    "-XX:+UseCompactObjectHeaders"
    "-XX:+AlwaysPreTouch"
    "-XX:+DisableExplicitGC"
    "-XX:+PerfDisableSharedMem"
    "-XX:+UnlockExperimentalVMOptions"
    "-XX:+UseG1GC"
    "-XX:G1HeapRegionSize=8M"
    "-XX:G1MaxNewSizePercent=40"
    "-XX:G1MixedGCCountTarget=4"
    "-XX:G1MixedGCLiveThresholdPercent=90"
    "-XX:G1NewSizePercent=30"
    "-XX:G1RSetUpdatingPauseTimePercent=5"
    "-XX:G1ReservePercent=20"
    "-XX:InitiatingHeapOccupancyPercent=15"
    "-XX:MaxTenuringThreshold=1"
    "-XX:SurvivorRatio=32"
  ];

  plugins = {
    Back = pkgs.fetchurl {
      url = "https://cdn.modrinth.com/data/eKlFGPMY/versions/8pC8l1Hx/Back-1.2.2.jar";
      sha256 = "e02b5e05f4a1f269b6effc197eea4b843d292183a797fce5771b2a0441e9ce27";
    };
  };

  bukkitSettings = {
    settings.connection-throttle = -1;
  };

  dataDir = "/var/lib/minecraft";
  console = config.systemd.sockets.minecraft-server.socketConfig.ListenFIFO;

  linkPlugins = lib.concatStrings (lib.mapAttrsToList (name: jar: ''
    ln -sfn ${jar} plugins/${name}.jar
  '') plugins);

  bukkitOverrides = pkgs.writeText "bukkit-overrides.json" (builtins.toJSON bukkitSettings);
  yq = lib.getExe pkgs.yq-go;

  backup = pkgs.writeShellApplication {
    name = "minecraft-backup";
    runtimeInputs = [ pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.gnused pkgs.gnutar pkgs.zstd config.systemd.package ];
    text = builtins.readFile ./minecraft-backup.sh;
  };
in
{
  options.homelab.minecraft = {
    port = lib.mkOption {
      type = lib.types.port;
      default = 25565;
      readOnly = true;
    };
    heap = lib.mkOption {
      type = lib.types.str;
      default = "6G";
    };
    backupDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/disk1/backup/minecraft";
    };
    backupsKept = lib.mkOption {
      type = lib.types.ints.positive;
      default = 7;
    };
  };

  config = {
    services.minecraft-server = {
      enable = true;
      eula = true;
      declarative = true;
      openFirewall = false;
      inherit dataDir;
      package = paper;
      jvmOpts = lib.concatStringsSep " " ([ "-Xms${cfg.heap}" "-Xmx${cfg.heap}" ] ++ paperFlags);
      whitelist = players;
      serverProperties = {
        server-port = cfg.port;
        motd = "Homelab";
        online-mode = true;
        white-list = true;
        enforce-whitelist = true;
        difficulty = "normal";
        gamemode = "survival";
        max-players = 4;
        view-distance = 10;
        simulation-distance = 8;
        max-world-size = 5000;
        spawn-protection = 0;
        enable-rcon = false;
        enable-query = false;
        enable-status = true;
        enable-jmx-monitoring = false;
      };
    };

    systemd.services.minecraft-server.preStart = lib.mkAfter ''
      install -d -m 0700 plugins
      find plugins -maxdepth 1 -type l -lname '/nix/store/*' -delete
      ${linkPlugins}
      [ -e bukkit.yml ] || echo '{}' > bukkit.yml
      ${yq} -i '. *= (load("${bukkitOverrides}") | ... style="")' bukkit.yml
    '';

    systemd.services.minecraft-server.serviceConfig = {
      Nice = 5;
      CPUWeight = 50;
      IOWeight = 50;
      MemoryMax = "9G";
      TimeoutStopSec = "2min";
    };

    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ cfg.port ];

    systemd.services.minecraft-backup = {
      description = "Archive the Minecraft world and keep the newest few";
      unitConfig.RequiresMountsFor = [ cfg.backupDir dataDir ];
      serviceConfig = {
        Type = "oneshot";
        Nice = 10;
        IOSchedulingClass = "idle";
        ExecStart = lib.escapeShellArgs [ (lib.getExe backup) dataDir cfg.backupDir console (toString cfg.backupsKept) ];
      };
    };

    systemd.timers.minecraft-backup = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 10:00:00 UTC";
        Persistent = true;
        RandomizedDelaySec = "10m";
      };
    };
  };
}
