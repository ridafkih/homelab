{ config, lib, inputs, ... }:
let
  nixFilesIn = dir:
    lib.mapAttrsToList (name: _: dir + "/${name}") (
      lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) (builtins.readDir dir)
    );
  siblings = builtins.filter (path: baseNameOf path != "default.nix") (nixFilesIn ./.);
  user = config.homelab.user;
in
{
  imports =
    siblings
    ++ nixFilesIn ../../modules
    ++ [
      inputs.sops-nix.nixosModules.sops
      inputs.disko.nixosModules.disko
    ];

  networking.hostName = "homelab";
  system.stateVersion = "26.05";

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  users.users.${user} = {
    isNormalUser = true;
    uid = config.homelab.uid;
    group = user;
    extraGroups = [ "wheel" "docker" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHMWIgp95BNiFer80VyOQGsnwu0bUABWfALi0bnjMg8N"
      "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIJbeujtDnc9lSolFiJ4qeXL9RLNz/yVKd1MaQuuxJmUJAAAABHNzaDo="
      "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIJQal5s00FOrB3fzVmBdTJVLe54VNpjMsveD/YYsi4VqAAAABHNzaDo="
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA5LPsxu3CaoQy8pV9oRXjRpqXNTUdEksM6sqZiTdG6U"
    ];
  };
  users.groups.${user}.gid = config.homelab.gid;
  users.groups.docker = { };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  security.sudo.wheelNeedsPassword = false;

  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) config.homelab.unfreeAllow;

  boot.loader.systemd-boot.enable = true;
}
