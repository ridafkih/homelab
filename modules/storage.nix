{ config, lib, options, pkgs, utils, ... }:
let
  diskOptions = [ "defaults" "nofail" "noatime" "x-systemd.device-timeout=10min" "x-systemd.device-bound" ];

  disks = {
    "/mnt/disk1" = "fa876494-200f-4c5d-95d6-0db79304bed7";
    "/mnt/disk2" = "62a0f9e6-258d-4ae7-a952-78c462d51c49";
  };

  mountUnitOf = path: "${utils.escapeSystemdPath path}.mount";

  dataDisk = uuid: {
    device = "/dev/disk/by-uuid/${uuid}";
    fsType = "ext4";
    options = diskOptions;
  };

  mounts = lib.mapAttrs (_: dataDisk) disks // {
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
      ] ++ map (unit: "x-systemd.wanted-by=${unit}") diskUnits ++ [
        "nofail"
        "fsname=mergerfs"
      ];
    };
  };

  remountService = "data-remount.service";

  mountOnArrival = lib.concatStrings (
    lib.mapAttrsToList (_: uuid: ''
      ACTION!="remove", SUBSYSTEM=="block", ENV{ID_FS_UUID}=="${uuid}", ENV{SYSTEMD_WANTS}+="${remountService}"
    '') disks
  );

  diskUnits = map mountUnitOf (lib.attrNames disks);
  guardedPaths = lib.attrNames mounts;
  guardedUnits = map mountUnitOf guardedPaths;
in
{
  config = lib.mkMerge [
    {
      fileSystems = mounts;
      system.fsPackages = [ pkgs.mergerfs ];
      environment.systemPackages = [ pkgs.mergerfs ];
      services.udev.extraRules = mountOnArrival;

      systemd.services = lib.mkMerge [
        (lib.mkIf config.virtualisation.docker.enable {
          docker = {
            unitConfig.RequiresMountsFor = guardedPaths;
            bindsTo = guardedUnits;
            after = guardedUnits;
            wantedBy = [ "data.mount" ];
          };
        })
        {
          data-remount = {
            description = "Mount /data once a data disk appears";
            after = diskUnits;
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${config.systemd.package}/bin/systemctl start --no-block data.mount";
            };
          };
        }
        (lib.mkIf config.services.smartd.enable {
          smartd = {
            wants = diskUnits;
            after = diskUnits;
            wantedBy = diskUnits;
          };
        })
      ];
    }
    (lib.optionalAttrs (options ? virtualisation.fileSystems) {
      virtualisation.fileSystems = mounts;
    })
  ];
}
