{ config, lib, ... }:
let
  generatorUnit = "nvidia-container-toolkit-cdi-generator.service";
  persistencedUnit = "nvidia-persistenced.service";
in
{
  config = lib.mkIf config.homelab.gpu.enable {
    homelab.unfreeAllow = [
      "nvidia-x11"
      "nvidia-persistenced"
    ];

    services.xserver.videoDrivers = [ "nvidia" ];

    hardware.nvidia = {
      open = true;
      package = config.boot.kernelPackages.nvidiaPackages.production;
      nvidiaPersistenced = true;
      modesetting.enable = false;
      nvidiaSettings = false;
    };

    boot.kernelModules = [
      "nvidia"
      "nvidia_uvm"
    ];

    hardware.nvidia-container-toolkit.enable = true;

    systemd.services.nvidia-container-toolkit-cdi-generator = {
      requiredBy = lib.mkForce [ ];
      after = [
        "systemd-modules-load.service"
        persistencedUnit
      ];
      wants = [ persistencedUnit ];
    };

    systemd.services.docker = {
      after = [
        generatorUnit
        persistencedUnit
      ];
      wants = [
        generatorUnit
        persistencedUnit
      ];
    };
  };
}
