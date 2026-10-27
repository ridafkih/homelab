{ config, ... }:
{
  networking.useNetworkd = true;
  networking.useDHCP = false;
  networking.tempAddresses = "disabled";

  systemd.network = {
    enable = true;

    config = {
      networkConfig = {
        ManageForeignRoutingPolicyRules = false;
        ManageForeignRoutes = false;
      };
      dhcpV4Config.DUIDType = "vendor";
    };

    networks."10-wlp9s0" = {
      matchConfig.Name = "wlp9s0";
      linkConfig.Unmanaged = true;
    };

    networks."20-wired" = {
      matchConfig.Name = config.homelab.lan.interface;
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = true;
      };
      dhcpV4Config = {
        ClientIdentifier = "duid";
        IAID = 3055685611;
        UseDNS = false;
      };
      ipv6AcceptRAConfig.UseDNS = false;
    };
  };
}
