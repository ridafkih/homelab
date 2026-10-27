{ config, lib, pkgs, ... }:
let
  cfg = config.homelab;
  edge = cfg.cloudflareTunnelEdge;

  floor = { priority = 5300; selector = "unreachable"; };

  carveOuts = edges:
    map (prefix: { priority = 5200; selector = "to ${prefix} lookup main"; }) edges
    ++ [
      { priority = 5205; selector = "fwmark 0x80000/0xff0000 lookup main"; }
      { priority = 5280; selector = "lookup main suppress_prefixlength 0"; }
    ];

  prunedPriorities = [ 5200 5205 5280 ];

  ensureLine = family: rule: "ensure ${family} ${toString rule.priority} ${rule.selector}";

  pruneLine = family: rules: priority:
    let
      wanted = map (rule: rule.selector) (builtins.filter (rule: rule.priority == priority) rules);
    in
    "prune ${family} ${toString priority} ${lib.escapeShellArgs wanted}";

  reconcile = family: edges:
    let
      rules = carveOuts edges;
    in
    lib.concatLines (
      [ (ensureLine family floor) ]
      ++ map (ensureLine family) rules
      ++ map (pruneLine family rules) prunedPriorities
    );

  egressPolicy = pkgs.writeShellApplication {
    name = "egress-policy";
    runtimeInputs = [ pkgs.iproute2 pkgs.gnused pkgs.gnugrep ];
    text = ''
      selectors() {
        ip "$1" rule show pref "$2" | sed -E 's/^[0-9]+:[[:space:]]+//; s/^from all //; s/ proto [^ ]+//g; s/[[:space:]]+$//'
      }

      ensure() {
        local family="$1" priority="$2"
        shift 2
        if ! selectors "$family" "$priority" | grep -qxF "$*"; then
          ip "$family" rule add pref "$priority" "$@"
        fi
      }

      prune() {
        local family="$1" priority="$2"
        shift 2
        local current wanted keep
        while read -r current; do
          [ -n "$current" ] || continue
          keep=false
          for wanted in "$@"; do
            if [ "$current" = "$wanted" ]; then
              keep=true
            fi
          done
          if [ "$keep" = false ]; then
            read -r -a fields <<< "$current"
            ip "$family" rule del pref "$priority" "''${fields[@]}"
          fi
        done < <(selectors "$family" "$priority")
      }

      ${reconcile "-4" edge.ipv4}
      ${reconcile "-6" edge.ipv6}
    '';
  };
in
{
  options.homelab.egress.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
  };

  config = lib.mkIf cfg.egress.enable {
    assertions = [
      {
        assertion = edge.ipv4 != [ ];
        message = "homelab.cloudflareTunnelEdge.ipv4 must list the Cloudflare tunnel edge prefixes";
      }
      {
        assertion = edge.ipv6 != [ ];
        message = "homelab.cloudflareTunnelEdge.ipv6 must list the Cloudflare tunnel edge prefixes";
      }
      {
        assertion =
          !config.systemd.network.enable
          || (config.systemd.network.config.networkConfig.ManageForeignRoutingPolicyRules or true) == false;
        message = "systemd-networkd must keep foreign routing policy rules: set ManageForeignRoutingPolicyRules = false";
      }
    ];

    systemd.services.egress-policy = {
      description = "Whole-box egress policy routing and kill switch";
      wantedBy = [ "sysinit.target" ];
      wants = [ "network-pre.target" ];
      before = [ "network-pre.target" "tailscaled.service" "docker.service" ];
      unitConfig.DefaultDependencies = false;
      stopIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe egressPolicy;
      };
    };
  };
}
