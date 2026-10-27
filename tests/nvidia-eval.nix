{ pkgs, self, lib }:
let
  host = self.nixosConfigurations.homelab;

  withGpu = enable: host.extendModules {
    modules = [
      {
        homelab.gpu.enable = lib.mkForce enable;
        virtualisation.docker.enable = lib.mkForce true;
      }
    ];
  };

  on = (withGpu true).config;
  off = (withGpu false).config;

  generator = "nvidia-container-toolkit-cdi-generator";
  generatorUnit = "${generator}.service";
  persistencedUnit = "nvidia-persistenced.service";

  evaluates = value: (builtins.tryEval (builtins.deepSeq value true)).success;
  drvEvaluates = drv: (builtins.tryEval (builtins.seq drv.drvPath true)).success;

  nameOf = pkg: pkg.pname or pkg.name or "";
  mentionsNvidia = pkgList: builtins.any (pkg: lib.hasInfix "nvidia" (lib.toLower (nameOf pkg))) pkgList;

  unitList = cfg: unit: field: cfg.systemd.services.${unit}.${field} or [ ];
  dockerList = cfg: unitList cfg "docker";

  driverOn = builtins.elem "nvidia" on.services.xserver.videoDrivers;
  withDriver = check: driverOn && check;

  majorOf = version: lib.toInt (builtins.head (lib.splitString "." version));

  forbiddenWords = [
    ("cuda" + "Support")
    ("enable" + "Nvidia")
  ];
  skippedDirs = [ "docs/decisions" ];
  filesUnder = rel:
    let
      dir = if rel == "" then self else self + "/${rel}";
      join = name: if rel == "" then name else "${rel}/${name}";
    in
    lib.concatLists (
      lib.mapAttrsToList (
        name: type:
        if type == "directory" then
          (if builtins.elem (join name) skippedDirs then [ ] else filesUnder (join name))
        else if type == "regular" then
          [ (join name) ]
        else
          [ ]
      ) (builtins.readDir dir)
    );
  readable = rel:
    let attempt = builtins.tryEval (builtins.readFile (self + "/${rel}"));
    in if attempt.success then attempt.value else "";
  filesWith = word: builtins.filter (rel: lib.hasInfix word (readable rel)) (filesUnder "");
  forbiddenHits = lib.concatMap filesWith forbiddenWords;

  archFiles = [
    "host/etc/systemd/system/nvidia-docker-arch.service"
    "host/etc/systemd/system/docker.service.d/nvidia-uvm.conf"
  ];

  expectations = {
    offNoNvidiaVideoDriver = !(builtins.elem "nvidia" off.services.xserver.videoDrivers);
    offNoContainerToolkit = off.hardware.nvidia-container-toolkit.enable == false;
    offNoNvidiaSystemPackages = !(mentionsNvidia off.environment.systemPackages);
    offNoNvidiaModulePackages = !(mentionsNvidia off.boot.extraModulePackages);
    offNoNvidiaKernelModules = !(builtins.any (lib.hasPrefix "nvidia") off.boot.kernelModules);
    offNoGenerator = !(off.systemd.services ? ${generator});
    offNoPersistenced = !(off.systemd.services ? nvidia-persistenced);
    offDockerAfterHasNoGenerator = !(builtins.elem generatorUnit (dockerList off "after"));
    offDockerWantsHasNoGenerator = !(builtins.elem generatorUnit (dockerList off "wants"));
    offUnfreeAllowHasNoNvidia = !(builtins.any (lib.hasPrefix "nvidia") off.homelab.unfreeAllow);
    offToplevelEvaluates = drvEvaluates off.system.build.toplevel;

    onNvidiaVideoDriver = driverOn;
    onXserverStaysOff = on.services.xserver.enable == false;
    onOpenModule = withDriver (on.hardware.nvidia.open == true);
    onModesettingOff = withDriver (on.hardware.nvidia.modesetting.enable == false);
    onPersistenced = withDriver (on.hardware.nvidia.nvidiaPersistenced == true);
    onNvidiaSettingsOff = withDriver (on.hardware.nvidia.nvidiaSettings == false);
    onProductionBranch = withDriver (on.hardware.nvidia.package.version == on.boot.kernelPackages.nvidiaPackages.production.version);
    onDriverAtLeast595 = withDriver (majorOf on.hardware.nvidia.package.version >= 595);
    onKernel618 = lib.hasPrefix "6.18" on.boot.kernelPackages.kernel.version;
    onKernelModules =
      builtins.elem "nvidia" on.boot.kernelModules && builtins.elem "nvidia_uvm" on.boot.kernelModules;
    onNoNomodeset = !(builtins.any (lib.hasInfix "nomodeset") on.boot.kernelParams);
    onNoDrmBlacklistParam = !(builtins.any (param: lib.hasInfix "module_blacklist" param && lib.hasInfix "nvidia_drm" param) on.boot.kernelParams);
    onNoDrmBlacklist = !(builtins.elem "nvidia_drm" on.boot.blacklistedKernelModules);
    onNoGlobalCuda = (on.nixpkgs.config.${builtins.head forbiddenWords} or false) == false;

    onContainerToolkit = on.hardware.nvidia-container-toolkit.enable == true;
    onGeneratorUnitExists = on.systemd.services ? ${generator};
    onGeneratorAfterModulesLoad = builtins.elem "systemd-modules-load.service" (unitList on generator "after");
    onGeneratorAfterPersistenced = builtins.elem persistencedUnit (unitList on generator "after");
    onGeneratorWantsPersistenced = builtins.elem persistencedUnit (unitList on generator "wants");
    onDockerAfterGenerator = builtins.elem generatorUnit (dockerList on "after");
    onDockerAfterPersistenced = builtins.elem persistencedUnit (dockerList on "after");
    onDockerWantsGenerator = builtins.elem generatorUnit (dockerList on "wants");
    onDockerWantsPersistenced = builtins.elem persistencedUnit (dockerList on "wants");
    onDockerNeverRequiresGenerator =
      !(builtins.elem generatorUnit (dockerList on "requires"))
      && !(builtins.elem generatorUnit (dockerList on "requisite"))
      && !(builtins.elem generatorUnit (dockerList on "bindsTo"));
    onGeneratorNotRequiredByDocker = !(builtins.elem "docker.service" (unitList on generator "requiredBy"));
    onDockerNeverRequiresPersistenced = !(builtins.elem persistencedUnit (dockerList on "requires"));

    onUnfreeOnlyNvidiaNames = builtins.all (lib.hasPrefix "nvidia") on.homelab.unfreeAllow && on.homelab.unfreeAllow != [ ];
    onDriverAdmitted = withDriver (drvEvaluates on.hardware.nvidia.package);
    onKernelModuleAdmitted = withDriver (drvEvaluates on.hardware.nvidia.package.open);
    onPersistencedAdmitted = withDriver (drvEvaluates on.hardware.nvidia.package.persistenced);
    onToplevelEvaluates = drvEvaluates on.system.build.toplevel;

    archFilesDeleted = builtins.all (rel: !(builtins.pathExists (self + "/${rel}"))) archFiles;
    noForbiddenWords = forbiddenHits == [ ];
  };

  failed = builtins.attrNames (lib.filterAttrs (_: passed: !(evaluates passed) || !passed) expectations);
in
if failed != [ ] then
  throw "nvidia eval expectations failed: ${lib.concatStringsSep ", " failed}${
    lib.optionalString (forbiddenHits != [ ]) " (forbidden words in ${lib.concatStringsSep ", " forbiddenHits})"
  }"
else
  pkgs.runCommand "nvidia-eval" {
    driver = on.hardware.nvidia.package;
    kernelModule = on.hardware.nvidia.package.open;
    persistenced = on.hardware.nvidia.package.persistenced;
  } ''
    test -e "$kernelModule/lib/modules"
    find "$kernelModule/lib/modules" -name 'nvidia.ko*' | grep -q .
    find "$kernelModule/lib/modules" -name 'nvidia-uvm.ko*' | grep -q .
    test -x "$persistenced/bin/nvidia-persistenced"
    echo ok > "$out"
  ''
