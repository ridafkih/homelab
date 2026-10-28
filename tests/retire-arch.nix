{ pkgs, self, lib }:
let
  allowed = [
    ".github"
    ".gitignore"
    ".gitleaks.toml"
    ".sops.yaml"
    "LICENSE"
    "README.md"
    "apps"
    "compose.yaml"
    "docs"
    "flake.lock"
    "flake.nix"
    "homelab.env"
    "hosts"
    "modules"
    "scripts"
    "secrets"
    "tests"
  ];
  ownedByParallelSlices = [ ".github" ];
  retired = [ "host" "config" "openseo" "Makefile" ".env.example" ];

  present = builtins.attrNames (builtins.readDir self);
  extras = lib.subtractLists allowed present;
  missing = lib.subtractLists (present ++ ownedByParallelSlices) allowed;
  stillTracked = builtins.filter (name: builtins.pathExists (self + "/${name}")) retired;

  problems =
    lib.optional (stillTracked != [ ]) "Arch paths still tracked: ${lib.concatStringsSep " " stillTracked}"
    ++ lib.optional (extras != [ ]) "unexpected top-level entries: ${lib.concatStringsSep " " extras}"
    ++ lib.optional (missing != [ ]) "missing top-level entries: ${lib.concatStringsSep " " missing}";
in
if problems == [ ] then
  pkgs.runCommand "retire-arch" { } "echo ok > $out"
else
  throw "retire-arch: ${lib.concatStringsSep "; " problems}"
