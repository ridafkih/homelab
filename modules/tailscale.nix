{ ... }:
{
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
    openFirewall = true;
    extraSetFlags = [
      "--exit-node=auto:any"
      "--exit-node-allow-lan-access"
      "--accept-dns=false"
    ];
  };

  systemd.services.tailscaled.environment.TS_DEBUG_MTU = "1500";
}
