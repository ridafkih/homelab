{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.homelab = {
    user = mkOption {
      type = types.str;
      default = "rida";
    };
    uid = mkOption {
      type = types.int;
      default = 1000;
    };
    gid = mkOption {
      type = types.int;
      default = 1000;
    };
    checkoutDir = mkOption {
      type = types.str;
      default = "/home/rida/homelab";
    };
    dataDir = mkOption {
      type = types.str;
      default = "/home/rida/homelab/.data";
    };
    lan.interface = mkOption {
      type = types.str;
      default = "eno1";
    };
    cloudflareTunnelEdge = {
      ipv4 = mkOption {
        type = types.listOf types.str;
        default = [
          "198.41.192.0/24"
          "198.41.200.0/24"
          "198.41.218.0/24"
          "198.41.219.0/24"
        ];
      };
      ipv6 = mkOption {
        type = types.listOf types.str;
        default = [
          "2606:4700:a0::/48"
          "2606:4700:a1::/48"
          "2606:4700:a8::/48"
          "2606:4700:a9::/48"
        ];
      };
    };
    gpu.enable = mkOption {
      type = types.bool;
      default = true;
    };
    unfreeAllow = mkOption {
      type = types.listOf types.str;
      default = [ ];
    };
  };
}
