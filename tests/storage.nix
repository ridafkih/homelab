{ pkgs, self, lib }:
let
  disk1Uuid = "fa876494-200f-4c5d-95d6-0db79304bed7";
  disk2Uuid = "62a0f9e6-258d-4ae7-a952-78c462d51c49";
  archRootUuid = "070b9e43-dbb5-423d-bd0d-e474ebed2e86";
  archBootUuid = "BD5C-4E9B";
  nvmePath = "/dev/disk/by-id/nvme-WD_BLACK_SN850X_2000GB_23523B800268";

  storageModulePath = self + "/modules/storage.nix";
  disksPath = self + "/hosts/homelab/disks.nix";
  storageModule =
    if builtins.pathExists storageModulePath then storageModulePath else throw "modules/storage.nix is missing";

  diskOptions = [ "nofail" "noatime" "x-systemd.device-timeout=15s" ];
  dataOptions = [
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
  guardedPaths = [ "/mnt/disk1" "/mnt/disk2" "/data" ];
  guardedUnits = [ "mnt-disk1.mount" "mnt-disk2.mount" "data.mount" ];

  host = self.nixosConfigurations.homelab;
  cfg = host.config;
  withDocker = host.extendModules { modules = [ { virtualisation.docker.enable = true; } ]; };
  docker = withDocker.config.systemd.services.docker or { };

  strayDisk = host.extendModules {
    modules = [
      {
        disko.devices.disk.stray = {
          type = "disk";
          device = "/dev/sda";
          content = {
            type = "gpt";
            partitions.stray = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/stray";
              };
            };
          };
        };
      }
    ];
  };

  storageOnly = lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      self.nixosModules.options
      storageModule
      {
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "/dev/disk/by-label/probe";
          fsType = "ext4";
        };
        system.stateVersion = "26.05";
      }
    ];
  };

  evaluates = value: (builtins.tryEval (builtins.deepSeq value true)).success;
  holds = value: let result = builtins.tryEval value; in result.success && result.value == true;
  includesAll = wanted: present: builtins.all (item: builtins.elem item present) wanted;
  listOf = value: if builtins.isList value then value else lib.splitString " " (toString value);

  fsOf = path: cfg.fileSystems.${path} or null;
  hasFs = path: fsOf path != null;
  diskMountedBy = path: uuid:
    hasFs path
    && (fsOf path).device == "/dev/disk/by-uuid/${uuid}"
    && (fsOf path).fsType == "ext4"
    && includesAll diskOptions (fsOf path).options;

  failingAssertions = config:
    builtins.length (
      builtins.filter (entry: let result = builtins.tryEval entry.assertion; in result.success && result.value == false)
        config.assertions
    );

  diskoDisks = cfg.disko.devices.disk or { };
  diskoDevices = lib.mapAttrsToList (_: disk: disk.device) diskoDisks;
  firstDisk = if diskoDisks == { } then { } else lib.head (lib.attrValues diskoDisks);
  nvmePartitions = lib.attrValues (firstDisk.content.partitions or { });
  partitionAt = mountpoint:
    lib.findFirst (partition: (partition.content.mountpoint or null) == mountpoint) null nvmePartitions;
  esp = partitionAt "/boot";
  root = partitionAt "/";

  hashChar = builtins.fromJSON ''"\u0023"'';
  shellFallback = ":" + "-";
  ownedSources = [ "modules/storage.nix" "hosts/homelab/disks.nix" "tests/storage.nix" ];
  sourceOf = name: let path = self + "/${name}"; in if builtins.pathExists path then builtins.readFile path else "";
  disksSource = sourceOf "hosts/homelab/disks.nix";

  usesDevice = needle: lib.any (fs: lib.hasInfix needle (fs.device or "")) (lib.attrValues cfg.fileSystems);

  expectations = {
    storageModuleExists = builtins.pathExists storageModulePath;
    disksFileExists = builtins.pathExists disksPath;
    archFstabDeleted = !(builtins.pathExists (self + "/host/etc/fstab"));
    archStorageGuardDeleted = !(builtins.pathExists (self + "/host/etc/systemd/system/docker.service.d/storage-guard.conf"));

    disk1ByUuid = diskMountedBy "/mnt/disk1" disk1Uuid;
    disk2ByUuid = diskMountedBy "/mnt/disk2" disk2Uuid;
    dataIsMergerfs =
      hasFs "/data"
      && (fsOf "/data").fsType == "fuse.mergerfs"
      && (fsOf "/data").device == "/mnt/disk1:/mnt/disk2";
    dataKeepsTodaysOptions = hasFs "/data" && includesAll dataOptions (fsOf "/data").options;
    dataDependsOnBothDisks = hasFs "/data" && includesAll [ "/mnt/disk1" "/mnt/disk2" ] (fsOf "/data").depends;
    noTimeMachineMount =
      !(lib.any (path: lib.hasInfix "timemachine" path) (lib.attrNames cfg.fileSystems))
      && !(lib.any (fs: builtins.elem "loop" (fs.options or [ ])) (lib.attrValues cfg.fileSystems));
    noArchSystemUuids = !(usesDevice archRootUuid) && !(usesDevice archBootUuid);

    mergerfsInFsPackages = lib.any (package: lib.getName package == "mergerfs") cfg.system.fsPackages;
    mergerfsInSystemPackages = lib.any (package: lib.getName package == "mergerfs") cfg.environment.systemPackages;

    dockerRequiresMounts = includesAll guardedPaths (listOf (docker.unitConfig.RequiresMountsFor or [ ]));
    dockerBindsToMounts = includesAll guardedUnits (docker.bindsTo or [ ]);
    dockerAfterMounts = includesAll guardedUnits (docker.after or [ ]);
    storageLeavesDockerOff =
      storageOnly.config.virtualisation.docker.enable == false
      && !(storageOnly.config.systemd.services ? docker);

    diskoOnlyNvme = diskoDevices == [ nvmePath ];
    diskoGpt = (firstDisk.content.type or null) == "gpt";
    espIsOneGigVfat =
      esp != null
      && esp.size == "1G"
      && esp.type == "EF00"
      && esp.content.format == "vfat"
      && builtins.elem "umask=0077" (esp.content.mountOptions or [ ]);
    rootIsExt4 = root != null && root.content.format == "ext4";
    rootFromDisko =
      hasFs "/" && (fsOf "/").fsType == "ext4" && (fsOf "/").device != "/dev/disk/by-label/nixos";
    bootFromDisko = hasFs "/boot" && (fsOf "/boot").fsType == "vfat";
    strayDiskFailsEval = failingAssertions strayDisk.config > failingAssertions cfg;

    disksNamesNvmeById = lib.hasInfix nvmePath disksSource;
    disksNeverNamesSdDevices = !(lib.hasInfix "/dev/sd" disksSource);
    disksNeverNamesByUuid = !(lib.hasInfix "by-uuid" disksSource);
    disksNeverNamesKernelNvme = !(lib.hasInfix "/dev/nvme" disksSource);

    noComments = builtins.all (name: !(lib.hasInfix hashChar (sourceOf name))) ownedSources;
    noShellFallbacks = builtins.all (name: !(lib.hasInfix shellFallback (sourceOf name))) ownedSources;
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !(evaluates passed) || !(holds passed)) expectations);

  vm = pkgs.testers.runNixOSTest {
    name = "storage-vm";
    nodes.machine = {
      imports = [ self.nixosModules.options storageModule ];
      virtualisation.memorySize = 1536;
      virtualisation.docker.enable = true;
      virtualisation.emptyDiskImages = [
        {
          size = 8192;
          driveConfig.deviceExtraOpts.serial = "disk1";
        }
        {
          size = 8192;
          driveConfig.deviceExtraOpts.serial = "disk2";
        }
      ];
      environment.systemPackages = [ pkgs.e2fsprogs ];
    };
    testScript = ''
      def show(prop, unit="docker.service"):
          return machine.succeed(f"systemctl show -p {prop} --value {unit}").split()

      machine.wait_for_unit("multi-user.target")
      machine.fail("mountpoint -q /mnt/disk1")
      machine.fail("mountpoint -q /mnt/disk2")
      machine.fail("mountpoint -q /data")
      machine.fail("systemctl is-active docker.service")

      machine.succeed("udevadm settle")
      machine.succeed("test -b /dev/disk/by-id/virtio-disk1")
      machine.succeed("test -b /dev/disk/by-id/virtio-disk2")
      machine.succeed("mkfs.ext4 -q -F -U ${disk1Uuid} /dev/disk/by-id/virtio-disk1")
      machine.succeed("mkfs.ext4 -q -F -U ${disk2Uuid} /dev/disk/by-id/virtio-disk2")
      machine.succeed("udevadm settle && sync")
      machine.shutdown()

      machine.start()
      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("mnt-disk1.mount")
      machine.wait_for_unit("mnt-disk2.mount")
      machine.wait_for_unit("data.mount")

      assert machine.succeed("findmnt -rno UUID /mnt/disk1").strip() == "${disk1Uuid}"
      assert machine.succeed("findmnt -rno UUID /mnt/disk2").strip() == "${disk2Uuid}"
      assert machine.succeed("findmnt -rno FSTYPE /mnt/disk1").strip() == "ext4"
      assert machine.succeed("findmnt -rno FSTYPE /mnt/disk2").strip() == "ext4"
      machine.succeed("findmnt -rno OPTIONS /mnt/disk1 | tr , '\\n' | grep -qx noatime")
      machine.succeed("findmnt -rno OPTIONS /mnt/disk2 | tr , '\\n' | grep -qx noatime")
      assert machine.succeed("findmnt -rno FSTYPE /data").strip() == "fuse.mergerfs"
      assert machine.succeed("findmnt -rno SOURCE /data").strip() == "mergerfs"

      machine.succeed("echo probe > /data/probe && sync")
      machine.succeed("test -f /mnt/disk1/probe || test -f /mnt/disk2/probe")
      assert machine.succeed("cat /data/probe").strip() == "probe"

      machine.wait_for_unit("docker.service")
      requires = show("RequiresMountsFor")
      for path in ["/mnt/disk1", "/mnt/disk2", "/data"]:
          assert path in requires, f"RequiresMountsFor lacks {path}: {requires}"
      binds = show("BindsTo")
      after = show("After")
      for unit in ["mnt-disk1.mount", "mnt-disk2.mount", "data.mount"]:
          assert unit in binds, f"BindsTo lacks {unit}: {binds}"
          assert unit in after, f"After lacks {unit}: {after}"

      machine.succeed("systemctl stop mnt-disk2.mount")
      machine.wait_until_fails("systemctl is-active data.mount")
      machine.wait_until_fails("systemctl is-active docker.service")
      machine.fail("mountpoint -q /data")
    '';
  };
in
pkgs.runCommand "storage" {
  vm = if failed == [ ] then vm else throw "homelab storage expectations failed: ${lib.concatStringsSep ", " failed}";
} ''
  echo ok > $out
''
