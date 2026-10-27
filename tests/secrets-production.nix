{ pkgs, self, lib }:
let
  host = self.nixosConfigurations.homelab;
  withTestModule = host.extendModules { modules = [ (self + "/secrets/test-module.nix") ]; };

  production = self + "/secrets/homelab.yaml";
  vm = self + "/secrets/vm.yaml";

  evaluates = value: (builtins.tryEval (builtins.deepSeq value true)).success;
  drvEvaluates = drv: (builtins.tryEval (builtins.seq drv.drvPath true)).success;
  sopsFileOf = cfg: toString cfg.homelab.secrets.sopsFile;

  expectations = {
    productionFileExists = builtins.pathExists production;
    secretsNixExists = builtins.pathExists (self + "/hosts/homelab/secrets.nix");
    hostUsesProductionFile = sopsFileOf host.config == toString production;
    hostDefaultSopsFileIsProduction = toString host.config.sops.defaultSopsFile == toString production;
    hostToplevelEvaluates = drvEvaluates host.config.system.build.toplevel;
    testModuleUsesVmFile = sopsFileOf withTestModule.config == toString vm;
    testModuleToplevelEvaluates = drvEvaluates withTestModule.config.system.build.toplevel;
  };

  failed = builtins.attrNames (lib.filterAttrs (_: passed: !(evaluates passed) || !passed) expectations);

  declaredNames = pkgs.writeText "declared-secret-names.json" (
    builtins.toJSON (builtins.attrNames host.config.sops.secrets)
  );
in
if failed != [ ] then
  throw "secrets production expectations failed: ${lib.concatStringsSep ", " failed}"
else
  pkgs.runCommand "secrets-production"
    {
      nativeBuildInputs = [ pkgs.yq-go pkgs.jq pkgs.gnugrep pkgs.coreutils pkgs.diffutils ];
      inherit production declaredNames;
      table = self + "/secrets/keys.tsv";
      sopsConfig = self + "/.sops.yaml";
    }
    ''
      set -euo pipefail

      yq -o=json '.' "$production" > production.json
      yq -o=json 'explode(.)' "$sopsConfig" > rules.json

      jq -r 'del(.sops) | paths(scalars) | map(tostring) | join("/")' production.json | LC_ALL=C sort > leaf-paths
      jq -r '.[]' "$declaredNames" | LC_ALL=C sort > declared-paths
      if ! diff -u declared-paths leaf-paths; then
        echo "secrets/homelab.yaml leaf paths differ from config.sops.secrets attrNames"
        exit 1
      fi

      cut -f3 "$table" | LC_ALL=C sort -u > table-paths
      if ! diff -u table-paths leaf-paths; then
        echo "secrets/homelab.yaml leaf paths differ from secrets/keys.tsv"
        exit 1
      fi

      plaintext=$(jq -r '
        del(.sops) | [paths(scalars) as $p | getpath($p) as $v
          | select(($v | type) != "string" or ($v != "" and ($v | startswith("ENC[AES256_GCM,") | not)))
          | $p | map(tostring) | join("/")] | .[]' production.json)
      if [ -n "$plaintext" ]; then
        echo "leaves that are not sops ciphertext: $plaintext"
        exit 1
      fi

      allowed_empty=$(awk -F'\t' '$4 == "allow" { print $3 }' "$table" | LC_ALL=C sort -u)
      plain_empty=$(jq -r 'del(.sops) | [paths(scalars) as $p | select(getpath($p) == "") | $p | map(tostring) | join("/")] | .[]' production.json | LC_ALL=C sort)
      extra_empty=$(LC_ALL=C comm -13 <(echo "$allowed_empty") <(echo "$plain_empty") | grep . || true)
      if [ -n "$extra_empty" ]; then
        echo "empty leaves not allowed by secrets/keys.tsv: $extra_empty"
        exit 1
      fi

      expected_recipients=$(jq -r '
        [.creation_rules[] | select(.path_regex == "^secrets/homelab\\.yaml$")] as $rules
        | if ($rules | length) != 1 then error("expected one rule for secrets/homelab.yaml") else $rules[0] end
        | [.key_groups[].age[]] | sort | join(",")' rules.json)
      actual_recipients=$(jq -r '[.sops.age[].recipient] | sort | join(",")' production.json)
      if [ "$actual_recipients" != "$expected_recipients" ]; then
        echo "secrets/homelab.yaml must be encrypted to exactly the .sops.yaml host and admin recipients"
        exit 1
      fi

      if grep -qE 'AGE-SECRET-KEY|BEGIN (OPENSSH|PGP|RSA|EC) PRIVATE' "$production"; then
        echo "secrets/homelab.yaml holds private key material"
        exit 1
      fi

      touch "$out"
    ''
