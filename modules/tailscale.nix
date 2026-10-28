{ config, lib, pkgs, ... }:
let
  mullvadExit = pkgs.writeShellApplication {
    name = "mullvad-exit";
    runtimeInputs = [ config.services.tailscale.package pkgs.jq pkgs.gnused pkgs.coreutils ];
    text = builtins.readFile ./mullvad-exit.sh;
  };
in
{
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
    openFirewall = true;
    extraSetFlags = [
      "--exit-node-allow-lan-access"
      "--accept-dns=false"
    ];
  };

  systemd.services.tailscaled.environment.TS_DEBUG_MTU = "1500";

  systemd.services.mullvad-exit = lib.mkIf config.homelab.egress.enable {
    description = "Keep the Tailscale exit node on a Mullvad relay";
    after = [ "tailscaled.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe mullvadExit;
    };
  };

  systemd.timers.mullvad-exit = lib.mkIf config.homelab.egress.enable {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "1min";
    };
  };
}
