{ config, lib, options, pkgs, utils, ... }:
let
  diskOptions = [ "defaults" "nofail" "noatime" "x-systemd.device-timeout=15s" ];

  dataDisk = uuid: {
    device = "/dev/disk/by-uuid/${uuid}";
    fsType = "ext4";
    options = diskOptions;
  };

  mounts = {
    "/mnt/disk1" = dataDisk "fa876494-200f-4c5d-95d6-0db79304bed7";
    "/mnt/disk2" = dataDisk "62a0f9e6-258d-4ae7-a952-78c462d51c49";
    "/data" = {
      device = "/mnt/disk1:/mnt/disk2";
      fsType = "fuse.mergerfs";
      depends = [ "/mnt/disk1" "/mnt/disk2" ];
      options = [
        "allow_other"
        "cache.files=auto-full"
        "dropcacheonclose=false"
        "category.create=mfs"
        "func.readdir=cor:4"
        "statfs=base"
        "cache.statfs=60"
        "moveonenospc=true"
        "x-systemd.requires=/mnt/disk1"
        "x-systemd.requires=/mnt/disk2"
        "nofail"
        "fsname=mergerfs"
      ];
    };
  };

  guardedPaths = lib.attrNames mounts;
  guardedUnits = map (path: "${utils.escapeSystemdPath path}.mount") guardedPaths;
in
{
  config = lib.mkMerge [
    {
      fileSystems = mounts;
      system.fsPackages = [ pkgs.mergerfs ];
      environment.systemPackages = [ pkgs.mergerfs ];

      systemd.services = lib.mkIf config.virtualisation.docker.enable {
        docker = {
          unitConfig.RequiresMountsFor = guardedPaths;
          bindsTo = guardedUnits;
          after = guardedUnits;
        };
      };
    }
    (lib.optionalAttrs (options ? virtualisation.fileSystems) {
      virtualisation.fileSystems = mounts;
    })
  ];
}
