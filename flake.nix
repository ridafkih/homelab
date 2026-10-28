{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, ... }@inputs:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};
      nixFilesIn = dir:
        lib.mapAttrs' (name: _: lib.nameValuePair (lib.removeSuffix ".nix" name) (dir + "/${name}")) (
          lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) (builtins.readDir dir)
        );
      tests = lib.mapAttrs (_: file: import file { inherit pkgs self lib; }) (nixFilesIn ./tests);
      host = self.nixosConfigurations.homelab;
      vmChecks = [ "backup" "compose" "dns-firewall" "egress" "eval" "host-basics" "network" "secrets" "storage" ];
      unknownVmChecks = lib.subtractLists (builtins.attrNames tests) vmChecks;
      checksWithoutVm = removeAttrs tests vmChecks;
    in
    {
      nixosConfigurations.homelab = lib.nixosSystem {
        inherit system;
        specialArgs = { inherit self inputs; };
        modules = [ ./hosts/homelab ];
      };

      nixosModules.options = ./modules/options.nix;

      packages.${system}.checks-novm =
        if unknownVmChecks != [ ] then
          throw "vmChecks in flake.nix names tests that don't exist: ${lib.concatStringsSep " " unknownVmChecks}"
        else
          pkgs.linkFarm "checks-novm" (lib.mapAttrsToList (name: path: { inherit name path; }) checksWithoutVm);

      checks.${system} =
        if tests ? toplevel then
          throw "tests/toplevel.nix is reserved for the host build check"
        else
          tests // { toplevel = host.config.system.build.toplevel; };
    };
}
