{ config, ... }:
{
  homelab.secrets.sopsFile = ./vm.yaml;

  system.activationScripts.installTestAgeKey = {
    deps = [ "specialfs" ];
    text = ''
      install -D -m 0600 ${./test-age.key} ${config.sops.age.keyFile}
    '';
  };
  system.activationScripts.setupSecrets.deps = [ "installTestAgeKey" ];
}
