{ config, lib, ... }:
let
  nvme = "/dev/disk/by-id/nvme-WD_BLACK_SN850X_2000GB_23523B800268";
in
{
  disko.devices.disk.nvme = {
    type = "disk";
    device = nvme;
    content = {
      type = "gpt";
      partitions = {
        esp = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };

  assertions = lib.mapAttrsToList (name: disk: {
    assertion = disk.device == nvme;
    message = "disko disk ${name} targets ${disk.device}; only ${nvme} may be partitioned";
  }) config.disko.devices.disk;
}
