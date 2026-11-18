{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption types;

  exitLocation = types.submodule {
    options = {
      countryCode = mkOption {
        type = types.strMatching "[A-Z]{2}";
      };
      cityCode = mkOption {
        type = types.nullOr (types.strMatching "[A-Z]+");
        default = null;
      };
    };
  };

  exitPreferences = pkgs.writeText "mullvad-exit-preferences.json" (
    builtins.toJSON config.homelab.egress.mullvadExitPreferences
  );

  mullvadExit = pkgs.writeShellApplication {
    name = "mullvad-exit";
    runtimeInputs = [ config.services.tailscale.package pkgs.jq pkgs.gnused pkgs.coreutils ];
    text = builtins.readFile ./mullvad-exit.sh;
  };
in
{
  options.homelab.egress.mullvadExitPreferences = mkOption {
    type = types.listOf exitLocation;
  };

  config = {
    services.tailscale = {
      enable = true;
      useRoutingFeatures = "client";
      openFirewall = true;
      extraSetFlags = [
        "--exit-node-allow-lan-access"
        "--accept-dns=false"
        "--snat-subnet-routes=false"
      ];
    };

    systemd.services.tailscaled.environment.TS_DEBUG_MTU = "1500";

    systemd.services.mullvad-exit = lib.mkIf config.homelab.egress.enable {
      description = "Keep the Tailscale exit node on a Mullvad relay";
      after = [ "tailscaled.service" ];
      wantedBy = [ "tailscaled.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe mullvadExit} ${exitPreferences}";
      };
    };

    systemd.timers.mullvad-exit = lib.mkIf config.homelab.egress.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "1min";
      };
    };
  };
}
