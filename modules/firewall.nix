{ config, ... }:
{
  networking.firewall = {
    enable = true;
    trustedInterfaces = [ "tailscale0" ];
    allowedTCPPorts = [ 22 53 80 443 3000 3389 4317 4318 4327 4328 8006 ];
    allowedUDPPorts = [ 53 3389 ];
  };

  assertions = [
    {
      assertion = !config.networking.nftables.enable;
      message = "networking.nftables.enable must stay false: its flushRuleset wipes Docker's rules and the homelab_ingress table; the IPv6 ingress rule loads from homelab-ipv6-ingress.service instead.";
    }
  ];
}
