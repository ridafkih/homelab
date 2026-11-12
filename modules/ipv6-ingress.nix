{ pkgs, ... }:
let
  nft = "${pkgs.nftables}/bin/nft";
in
{
  systemd.services.homelab-ipv6-ingress = {
    description = "Drop public IPv6 to the reverse proxy ports";
    unitConfig.DefaultDependencies = false;
    before = [ "network-pre.target" "docker.service" ];
    wants = [ "network-pre.target" ];
    after = [ "local-fs.target" "systemd-modules-load.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${nft} -f ${./ipv6-ingress.nft}";
      ExecStop = "${nft} delete table ip6 homelab_ingress";
    };
  };
}
