{ pkgs, self, lib }:
let
  host = self.nixosConfigurations.homelab;
  prod = host.config;
  vm = prod.virtualisation.vmVariant;

  vmModulePath = self + "/hosts/homelab/vm.nix";
  scriptPath = self + "/scripts/vm-smoke.sh";
  hashChar = builtins.fromJSON ''"#"'';
  shellFallback = ":" + "-";
  sourceOf = path: if builtins.pathExists path then builtins.readFile path else "";

  smokeUnits = [ "homelab-vm-checkout" "homelab-smoke-tier" "homelab-smoke" ];
  hasUnit = cfg: name: cfg.systemd.services ? ${name};
  extraFilesOf = cfg: map toString (cfg.homelab.compose.extraFiles.homelab or [ ]);
  storeFilesOf = cfg: builtins.filter (lib.hasPrefix builtins.storeDir) (extraFilesOf cfg);
  isNogpu = lib.hasSuffix "apps/jellyfin/compose.nogpu.yaml";
  kernelParamsOf = cfg: cfg.boot.kernelParams or [ ];
  mentionsSmoke = builtins.any (lib.hasInfix "homelab.smoke");
  fs = cfg: path: cfg.fileSystems.${path} or { };
  virtioDisk = cfg: path:
    lib.hasPrefix "/dev/disk/by-id/virtio-" ((fs cfg path).device or "") && ((fs cfg path).autoFormat or false);
  windowsOff = cfg:
    !(hasUnit cfg "windows-compose")
    || !(cfg.systemd.services.windows-compose.enable or true)
    || (cfg.systemd.services.windows-compose.wantedBy or [ ]) == [ ];
  openseoCondition = cfg:
    let value = (cfg.systemd.services.openseo-compose.unitConfig or { }).ConditionKernelCommandLine or null;
    in if builtins.isList value then value else if value == null then [ ] else [ value ];
  isCommentLine = line: builtins.match "[[:space:]]*${hashChar}.*" line != null;

  vmSource = sourceOf vmModulePath;
  scriptSource = sourceOf scriptPath;
  scriptLines = lib.splitString "\n" scriptSource;
  vmLines = lib.splitString "\n" vmSource;

  expectations = {
    vmModulePresent = builtins.pathExists vmModulePath;
    scriptPresent = builtins.pathExists scriptPath;

    vmMemorySize = vm.virtualisation.memorySize == 6144;
    vmCores = vm.virtualisation.cores == 4;
    vmDiskSize = vm.virtualisation.diskSize == 40960;
    vmNoGraphics = vm.virtualisation.graphics == false;
    vmGpuOff = vm.homelab.gpu.enable == false;
    vmEgressOff = vm.homelab.egress.enable == false;
    vmNoEgressPolicy = !(hasUnit vm "egress-policy");
    vmSopsFileIsTestFile = lib.hasSuffix "secrets/vm.yaml" (toString vm.homelab.secrets.sopsFile);
    vmInstallsTestKey = vm.system.activationScripts ? installTestAgeKey;
    vmNogpuOverride = builtins.any isNogpu (extraFilesOf vm);
    vmCaddyOverride = builtins.length (builtins.filter (file: !(isNogpu file)) (storeFilesOf vm)) >= 1;
    vmTierOverride = builtins.elem "/run/homelab-smoke/tier.yaml" (extraFilesOf vm);
    vmDisk1Virtio = virtioDisk vm "/mnt/disk1";
    vmDisk2Virtio = virtioDisk vm "/mnt/disk2";
    vmDataMergerfs = (fs vm "/data").fsType or null == "fuse.mergerfs";
    vmDataKeepsDiskRequires =
      builtins.all (opt: builtins.elem opt ((fs vm "/data").options or [ ])) [
        "x-systemd.requires=/mnt/disk1"
        "x-systemd.requires=/mnt/disk2"
      ];
    vmSmokeUnits = builtins.all (hasUnit vm) smokeUnits;
    vmSmokeAfterCompose =
      builtins.all (unit: builtins.elem unit (vm.systemd.services.homelab-smoke.after or [ ])) [
        "homelab-compose.service"
        "openseo-compose.service"
      ];
    vmCheckoutBeforeCompose = builtins.elem "homelab-compose.service" (vm.systemd.services.homelab-vm-checkout.before or [ ]);
    vmTierBeforeCompose = builtins.elem "homelab-compose.service" (vm.systemd.services.homelab-smoke-tier.before or [ ]);
    vmWindowsOff = windowsOff vm;
    vmOpenseoOnlyInCore = openseoCondition vm == [ "homelab.smoke=core" ];
    vmComposeUnitsKept = hasUnit vm "homelab-compose" && hasUnit vm "openseo-compose";

    prodEgressOn = prod.homelab.egress.enable == true;
    prodEgressPolicy = hasUnit prod "egress-policy";
    prodGpuOn = prod.homelab.gpu.enable == true;
    prodSopsFileIsProduction = lib.hasSuffix "secrets/homelab.yaml" (toString prod.homelab.secrets.sopsFile);
    prodNoTestKey = !(prod.system.activationScripts ? installTestAgeKey);
    prodNoSmokeUnits = !(builtins.any (hasUnit prod) smokeUnits);
    prodNoVmOverrides = storeFilesOf prod == [ ] && !(builtins.any isNogpu (extraFilesOf prod));
    prodNoTierOverride = !(builtins.any (lib.hasInfix "homelab-smoke") (extraFilesOf prod));
    prodNoSmokeKernelParams = !(mentionsSmoke (kernelParamsOf prod));
    prodWindowsUnitKept = hasUnit prod "windows-compose" && !(windowsOff prod);
    prodOpenseoUnconditional = openseoCondition prod == [ ];
    prodDisk1ByUuid = lib.hasPrefix "/dev/disk/by-uuid/" ((fs prod "/mnt/disk1").device or "");
    prodDisk2ByUuid = lib.hasPrefix "/dev/disk/by-uuid/" ((fs prod "/mnt/disk2").device or "");

    vmModuleNoComments = !(builtins.any isCommentLine vmLines);
    vmModuleNoShellFallback = !(lib.hasInfix shellFallback vmSource);
    scriptNoComments = !(builtins.any isCommentLine (builtins.tail scriptLines));
    scriptNoShellFallback = !(lib.hasInfix shellFallback scriptSource);
    scriptPosixShebang = builtins.head scriptLines == "${hashChar}!/bin/sh";
  };

  failed = builtins.attrNames (lib.filterAttrs (_: ok: !ok) expectations);

  vmCaddyOverrides = builtins.filter (file: !(isNogpu file)) (storeFilesOf vm);

  check = pkgs.runCommand "vm-smoke-checks"
    {
      nativeBuildInputs = [ pkgs.shellcheck pkgs.gnugrep pkgs.coreutils pkgs.util-linux ];
    }
    ''
      set -eu
      script=${scriptPath}

      shellcheck -s sh "$script"

      for needle in \
        'systemd-run --user --scope' \
        'MemoryMax=7G' \
        'nice -n19' \
        'ionice -c3' \
        'flock' \
        'homelab-nixos-build' \
        'QEMU_KERNEL_PARAMS' \
        'homelab.smoke=' \
        'NIX_DISK_IMAGE' \
        'memory.peak' \
        'oom_kill' \
        'measurements.tsv' \
        'qcow2' \
        'trap' \
        'StartedAt' \
        'ss -ltn' \
        'system.build.vm' \
        'obs-signoz' \
        'obs-grafana'
      do
        grep -qF -- "$needle" "$script" || { echo "vm-smoke.sh does not mention: $needle"; exit 1; }
      done

      found=0
      for override in ${lib.concatStringsSep " " vmCaddyOverrides}; do
        for ref in $(grep -oE '${builtins.storeDir}/[A-Za-z0-9._+-]+' "$override" | sort -u); do
          [ -f "$ref" ] || continue
          if grep -q 'tls internal' "$ref"; then
            found=1
            if grep -q 'import cloudflare' "$ref"; then
              echo "VM Caddyfile $ref still imports cloudflare"
              exit 1
            fi
          fi
        done
      done
      [ "$found" = 1 ] || { echo "no VM Caddyfile with tls internal reached through homelab.compose.extraFiles"; exit 1; }

      stubs=$PWD/stubs
      calls=$PWD/calls
      mkdir -p "$stubs"
      : > "$calls"
      for tool in nix docker systemd-run qemu-system-x86_64 qemu-kvm ss flock git ssh; do
        printf '%s\n' '#!/bin/sh' "echo $tool \"\$*\" >> $calls" 'exit 0' > "$stubs/$tool"
        chmod +x "$stubs/$tool"
      done

      expect_refusal() {
        label=$1
        shift
        : > "$calls"
        if env PATH="$stubs:$PATH" HOME="$home" "$@" > out.log 2>&1; then
          echo "$label: vm-smoke.sh exited 0"
          cat out.log
          exit 1
        fi
        if [ -s "$calls" ]; then
          echo "$label: vm-smoke.sh ran tools before refusing:"
          cat "$calls"
          exit 1
        fi
      }

      home=$PWD/home
      mkdir -p "$home/homelab" "$home/homelab-nixos-build/vm-smoke"

      cd "$home/homelab-nixos-build/vm-smoke"
      expect_refusal "no tier" sh "$script"
      expect_refusal "unknown tier" sh "$script" bogus
      expect_refusal "two tiers" sh "$script" core media

      cd "$home/homelab"
      expect_refusal "inside ~/homelab" sh "$script" core

      ln -s "$home/homelab" "$home/homelab-link"
      cd "$home/homelab-link"
      expect_refusal "symlink to ~/homelab" sh "$script" core

      touch $out
    '';
in
if failed == [ ] then
  check
else
  throw "homelab vm-smoke expectations failed: ${lib.concatStringsSep ", " failed}"
