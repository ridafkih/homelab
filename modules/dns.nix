{ config, ... }:
{
  services.resolved.enable = false;

  networking.nameservers = [ "127.0.0.1" "1.1.1.1" ];
  networking.resolvconf.extraConfig = "resolv_conf_local_only=NO";

  assertions = [
    {
      assertion = !(config.virtualisation.docker.daemon.settings ? dns);
      message = "virtualisation.docker.daemon.settings must not set dns: containers resolve through the host, and a fixed dns key would bring back the tailnet-IP resolver.";
    }
  ];
}
