{ lib, ... }:
{
  homelab.secrets.sopsFile = lib.mkDefault ../../secrets/homelab.yaml;
}
