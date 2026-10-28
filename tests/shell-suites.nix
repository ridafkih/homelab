{ pkgs, self, lib }:
let
  suites = [
    "compose-lint.sh"
    "exposure.sh"
    "gitignore.sh"
    "readme-restore.sh"
  ];
  outsideTheSandbox = [
    "secrets-age-keys.sh"
    "secrets-repo.sh"
    "secrets-values.sh"
  ];
  shellTests = builtins.attrNames (lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".sh" name) (builtins.readDir ./.));
  unwired = lib.subtractLists (suites ++ outsideTheSandbox) shellTests;
in
if unwired != [ ] then
  throw "tests/${builtins.head unwired} is run by nothing: add it to suites in tests/shell-suites.nix, or to outsideTheSandbox and the README's test list"
else
pkgs.runCommand "shell-suites"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.diffutils
      pkgs.docker-compose
      pkgs.findutils
      pkgs.gawk
      pkgs.git
      pkgs.gitleaks
      pkgs.gnugrep
      pkgs.gnused
      pkgs.jq
    ];
  }
  ''
    export HOME=$TMPDIR
    cp -R ${self} work
    chmod -R u+w work
    cd work
    git init -q
    git add -A -f
    ${lib.concatMapStrings (suite: ''
      echo "== ${suite}"
      bash tests/${suite}
    '') suites}
    touch $out
  ''
