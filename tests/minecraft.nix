{ pkgs, self, lib }:
let
  cfg = self.nixosConfigurations.homelab.config;
  server = cfg.services.minecraft-server;
  props = server.serverProperties;
  port = cfg.homelab.minecraft.port;
  firewall = cfg.networking.firewall;
  uuidPattern = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";

  expectations = {
    declarative = server.declarative;
    onlineMode = props.online-mode;
    whitelistEnforced = props.white-list && props.enforce-whitelist;
    whitelistUuids = builtins.all (uuid: builtins.match uuidPattern uuid != null) (builtins.attrValues server.whitelist);
    noRcon = !props.enable-rcon;
    noQuery = !props.enable-query;
    portOnlyOnTailnet =
      !server.openFirewall
      && !(builtins.elem port firewall.allowedTCPPorts)
      && !(builtins.elem port firewall.allowedUDPPorts)
      && builtins.elem port firewall.interfaces.tailscale0.allowedTCPPorts
      && builtins.all (name: name == "tailscale0" || !(builtins.elem port (firewall.interfaces.${name}.allowedTCPPorts or [ ]))) (builtins.attrNames firewall.interfaces);
    paperPinned = server.package.version == "26.3-253";
    paperOnJava25 = lib.hasInfix "openjdk-headless-25" server.package.installPhase;
    heapBounded = lib.hasInfix "-Xmx${cfg.homelab.minecraft.heap}" server.jvmOpts && cfg.systemd.services.minecraft-server.serviceConfig.MemoryMax == "9G";
    backupsRotate = cfg.homelab.minecraft.backupsKept == 7 && lib.hasPrefix "/mnt/disk" cfg.homelab.minecraft.backupDir;
    backupTimer = cfg.systemd.timers.minecraft-backup.wantedBy == [ "timers.target" ];
  };

  failed = builtins.attrNames (lib.filterAttrs (_: passed: !passed) expectations);
in
if failed != [ ] then
  throw "minecraft expectations failed: ${lib.concatStringsSep ", " failed}"
else
  pkgs.runCommand "minecraft" { } "touch $out"
