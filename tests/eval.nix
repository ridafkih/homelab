{ pkgs, self, lib }:
let
  host = self.nixosConfigurations.homelab;
  cfg = host.config;
  opts = host.options;

  liveKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHMWIgp95BNiFer80VyOQGsnwu0bUABWfALi0bnjMg8N"
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIJbeujtDnc9lSolFiJ4qeXL9RLNz/yVKd1MaQuuxJmUJAAAABHNzaDo="
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIJQal5s00FOrB3fzVmBdTJVLe54VNpjMsveD/YYsi4VqAAAABHNzaDo="
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA5LPsxu3CaoQy8pV9oRXjRpqXNTUdEksM6sqZiTdG6U"
  ];

  withUnfreeAllow = names: host.extendModules {
    modules = [ { homelab.unfreeAllow = lib.mkForce names; } ];
  };
  pkgsOf = system: system.config._module.args.pkgs;
  evaluates = value: (builtins.tryEval (builtins.seq value true)).success;
  drvEvaluates = drv: evaluates drv.drvPath;
  nvidiaOf = system: (pkgsOf system).linuxPackages.nvidiaPackages.production;
  unrarOf = system: (pkgsOf system).unrar;

  noUnfree = withUnfreeAllow [ ];
  nvidiaOnly = withUnfreeAllow [ "nvidia-x11" ];

  probeDevice = "/dev/disk/by-label/eval-probe";
  overridden = host.extendModules {
    modules = [
      {
        fileSystems."/" = lib.mkOverride 1499 { device = probeDevice; fsType = "xfs"; };
        boot.loader.systemd-boot.enable = lib.mkOverride 1499 false;
      }
    ];
  };

  testNames = lib.mapAttrsToList (name: _: lib.removeSuffix ".nix" name) (
    lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) (
      builtins.readDir (self + "/tests")
    )
  );
  checkNames = builtins.attrNames self.checks.x86_64-linux;

  lock = builtins.fromJSON (builtins.readFile (self + "/flake.lock"));
  lockedInput = name: lock.nodes.${lock.nodes.root.inputs.${name}};

  hashChar = builtins.fromJSON ''"\u0023"'';
  shellFallback = ":" + "-";
  ownedSources = [
    "flake.nix"
    "hosts/homelab/default.nix"
    "modules/options.nix"
    "tests/eval.nix"
  ];
  sourceOf = name: builtins.readFile (self + "/${name}");

  user = cfg.users.users.rida;
  ssh = cfg.services.openssh.settings;

  expectations = {
    lanInterface = cfg.homelab.lan.interface == "eno1";
    homelabUser = cfg.homelab.user == "rida";
    homelabUid = cfg.homelab.uid == 1000;
    homelabGid = cfg.homelab.gid == 1000;
    checkoutDir = cfg.homelab.checkoutDir == "/home/rida/homelab";
    dataDir = cfg.homelab.dataDir == "/home/rida/homelab/.data";
    dirsAreStrings = opts.homelab.checkoutDir.type.name == "str" && opts.homelab.dataDir.type.name == "str";
    uidGidAreInts = opts.homelab.uid.type.name == "int" && opts.homelab.gid.type.name == "int";
    cloudflareEdgeIpv4 = cfg.homelab.cloudflareTunnelEdge.ipv4 == [
      "198.41.192.0/24"
      "198.41.200.0/24"
      "198.41.218.0/24"
      "198.41.219.0/24"
    ];
    cloudflareEdgeIpv6 = cfg.homelab.cloudflareTunnelEdge.ipv6 == [
      "2606:4700:a0::/48"
      "2606:4700:a1::/48"
      "2606:4700:a8::/48"
      "2606:4700:a9::/48"
    ];
    gpuEnabled = cfg.homelab.gpu.enable == true;
    unfreeAllowDefaultEmpty = opts.homelab.unfreeAllow.default == [ ];
    unfreeAllowIsStringList = opts.homelab.unfreeAllow.type.name == "listOf";
    droppedOptionsUndeclared =
      !(opts.homelab.lan ? ipv4Cidr)
      && !(opts.homelab ? dockerCidr)
      && !(opts.homelab ? tailnet);

    hostName = cfg.networking.hostName == "homelab";
    stateVersion = cfg.system.stateVersion == "26.05";
    hostSystem = (pkgsOf host).stdenv.hostPlatform.system == "x86_64-linux";
    flakesEnabled =
      builtins.elem "nix-command" cfg.nix.settings.experimental-features
      && builtins.elem "flakes" cfg.nix.settings.experimental-features;
    sopsModuleImported = opts ? sops;
    diskoModuleImported = opts ? disko;

    userIsNormal = user.isNormalUser;
    userUid = user.uid == cfg.homelab.uid;
    userGroup = user.group == cfg.homelab.user && cfg.users.groups.rida.gid == cfg.homelab.gid;
    userExtraGroups = builtins.elem "wheel" user.extraGroups && builtins.elem "docker" user.extraGroups;
    dockerGroupDeclared = cfg.users.groups ? docker;
    authorizedKeys = lib.sort lib.lessThan user.openssh.authorizedKeys.keys == lib.sort lib.lessThan liveKeys;

    sshEnabled = cfg.services.openssh.enable;
    sshNoPassword = ssh.PasswordAuthentication == false;
    sshNoKeyboardInteractive = ssh.KbdInteractiveAuthentication == false;
    sshNoRootLogin = ssh.PermitRootLogin == "no";
    sudoWithoutPassword = cfg.security.sudo.wheelNeedsPassword == false;

    unfreeRefusedOnHost = !(drvEvaluates (unrarOf host));
    nvidiaRefusedWhenNotAllowed = !(drvEvaluates (nvidiaOf noUnfree));
    nvidiaAdmittedWhenAllowed = drvEvaluates (nvidiaOf nvidiaOnly);
    unrarRefusedWhenOnlyNvidiaAllowed = !(drvEvaluates (unrarOf nvidiaOnly));

    rootPlaceholderIsWeak =
      cfg.fileSystems."/".device != "/dev/disk/by-label/nixos"
      || overridden.config.fileSystems."/".device == probeDevice;
    bootloaderPlaceholderIsWeak =
      opts.boot.loader.systemd-boot.enable.highestPrio < 1000
      || overridden.config.boot.loader.systemd-boot.enable == false;
    bootloaderIsSystemdBoot = cfg.boot.loader.systemd-boot.enable;

    optionsModuleExported = self ? nixosModules && self.nixosModules ? options;
    testsAutoRegistered = lib.sort lib.lessThan checkNames == lib.sort lib.lessThan (testNames ++ [ "toplevel" ]);
    toplevelCheckPresent = builtins.elem "toplevel" checkNames;

    nixpkgsPinned =
      let original = (lockedInput "nixpkgs").original;
      in original.type == "github" && original.owner == "NixOS" && original.repo == "nixpkgs" && original.ref == "nixos-26.05";
    sopsFollowsNixpkgs = (lockedInput "sops-nix").inputs.nixpkgs == [ "nixpkgs" ];
    diskoFollowsNixpkgs = (lockedInput "disko").inputs.nixpkgs == [ "nixpkgs" ];

    noComments = builtins.all (name: !(lib.hasInfix hashChar (sourceOf name))) ownedSources;
    noShellFallbacks = builtins.all (name: !(lib.hasInfix shellFallback (sourceOf name))) ownedSources;
  };

  failed = builtins.attrNames (lib.filterAttrs (_: passed: !(evaluates passed) || !passed) expectations);
in
pkgs.testers.runNixOSTest {
  name = "eval";
  nodes.machine = { config, ... }: {
    imports = [ self.nixosModules.options ];
    virtualisation.memorySize = 1024;
    environment.etc."homelab-lan-interface".text = config.homelab.lan.interface;
    environment.etc."homelab-eval".text =
      if failed == [ ] then "ok" else throw "homelab eval expectations failed: ${lib.concatStringsSep ", " failed}";
  };
  testScript = ''
    machine.wait_for_unit("multi-user.target")
    assert machine.succeed("cat /etc/homelab-lan-interface") == "eno1"
    assert machine.succeed("cat /etc/homelab-eval") == "ok"
  '';
}
