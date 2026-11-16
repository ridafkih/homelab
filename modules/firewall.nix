{ config, lib, ... }:
let
  committedEnv = builtins.listToAttrs (
    map
      (line: let parts = lib.splitString "=" line; in lib.nameValuePair (builtins.head parts) (lib.concatStringsSep "=" (builtins.tail parts)))
      (builtins.filter (line: line != "") (lib.splitString "\n" (builtins.readFile ../homelab.env)))
  );
  hyperAdminPort = 3912;
in
{
  networking.firewall = {
    enable = true;
    trustedInterfaces = [ "tailscale0" ];
    allowedTCPPorts = [ 22 53 80 443 3000 3389 4317 4318 4327 4328 8006 ];
    allowedUDPPorts = [ 53 3389 ];
    extraCommands = ''
      iptables -I nixos-fw -i ${committedEnv.HYPER_ADMIN_BRIDGE} -s ${committedEnv.HYPER_ADMIN_PROXY_ADDRESS} -p tcp --dport ${toString hyperAdminPort} -j nixos-fw-accept
    '';
  };

  assertions = [
    {
      assertion = !config.networking.nftables.enable;
      message = "networking.nftables.enable must stay false: its flushRuleset wipes Docker's rules and the homelab_ingress table; the IPv6 ingress rule loads from homelab-ipv6-ingress.service instead.";
    }
  ];
}
