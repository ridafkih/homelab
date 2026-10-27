{ pkgs, self, lib }:
let
  tab = "\t";

  oracleRows = [
    [ "adguard.env" "ADGUARD_PASSWORD_HASH" "adguard/ADGUARD_PASSWORD_HASH" "deny" ]
    [ "adguard.env" "ADGUARD_USER" "adguard/ADGUARD_USER" "deny" ]
    [ "authentik-tunnel.env" "TUNNEL_TOKEN" "authentik/AUTHENTIK_CLOUDFLARE_TUNNEL_TOKEN" "deny" ]
    [ "authentik.env" "AUTHENTIK_POSTGRESQL__PASSWORD" "authentik/AUTHENTIK_POSTGRESQL__PASSWORD" "deny" ]
    [ "authentik.env" "AUTHENTIK_POSTGRESQL__USER" "authentik/AUTHENTIK_POSTGRESQL__USER" "deny" ]
    [ "authentik.env" "AUTHENTIK_SECRET_KEY" "authentik/AUTHENTIK_SECRET_KEY" "deny" ]
    [ "authentik.env" "POSTGRES_PASSWORD" "authentik/AUTHENTIK_POSTGRESQL__PASSWORD" "deny" ]
    [ "authentik.env" "POSTGRES_USER" "authentik/AUTHENTIK_POSTGRESQL__USER" "deny" ]
    [ "caddy.env" "CLOUDFLARE_API_TOKEN" "caddy/CADDY_CLOUDFLARE_API_TOKEN" "deny" ]
    [ "grafana.env" "GF_SECURITY_ADMIN_PASSWORD" "grafana/GRAFANA_ADMIN_PASSWORD" "deny" ]
    [ "grafana.env" "GF_SECURITY_ADMIN_USER" "grafana/GRAFANA_ADMIN_USER" "deny" ]
    [ "openseo.env" "CONTEXT_API_KEY" "openseo/CONTEXT_API_KEY" "allow" ]
    [ "openseo.env" "DATAFORSEO_API_KEY" "openseo/DATAFORSEO_API_KEY" "deny" ]
    [ "openseo.env" "GOOGLE_CLIENT_ID" "openseo/GOOGLE_CLIENT_ID" "deny" ]
    [ "openseo.env" "GOOGLE_CLIENT_SECRET" "openseo/GOOGLE_CLIENT_SECRET" "deny" ]
    [ "openseo.env" "OPENROUTER_API_KEY" "openseo/OPENROUTER_API_KEY" "allow" ]
    [ "openseo.env" "STORAGE_ACCESS_KEY" "openseo/STORAGE_ACCESS_KEY" "deny" ]
    [ "openseo.env" "STORAGE_SECRET_KEY" "openseo/STORAGE_SECRET_KEY" "deny" ]
    [ "otel.env" "OTEL_AUTH_TOKEN" "otel/OTEL_AUTH_TOKEN" "deny" ]
    [ "ridash.env" "TUNNEL_TOKEN" "ridash/RIDASH_CLOUDFLARE_TUNNEL_TOKEN" "deny" ]
    [ "seafile.env" "DB_PASSWORD" "seafile/SEAFILE_MYSQL_PASSWORD" "deny" ]
    [ "seafile.env" "INIT_SEAFILE_ADMIN_EMAIL" "seafile/SEAFILE_ADMIN_EMAIL" "deny" ]
    [ "seafile.env" "INIT_SEAFILE_ADMIN_PASSWORD" "seafile/SEAFILE_ADMIN_PASSWORD" "deny" ]
    [ "seafile.env" "INIT_SEAFILE_MYSQL_ROOT_PASSWORD" "seafile/SEAFILE_MYSQL_ROOT_PASSWORD" "deny" ]
    [ "seafile.env" "JWT_PRIVATE_KEY" "seafile/SEAFILE_JWT_PRIVATE_KEY" "deny" ]
    [ "seafile.env" "MYSQL_ROOT_PASSWORD" "seafile/SEAFILE_MYSQL_ROOT_PASSWORD" "deny" ]
    [ "seafile.env" "REDIS_PASSWORD" "seafile/SEAFILE_REDIS_PASSWORD" "deny" ]
    [ "seafile.env" "SEAFILE_MYSQL_DB_PASSWORD" "seafile/SEAFILE_MYSQL_PASSWORD" "deny" ]
    [ "signoz.env" "SIGNOZ_TOKENIZER_JWT_SECRET" "signoz/SIGNOZ_JWT_SECRET" "deny" ]
    [ "tailscale-funnel.env" "TS_AUTHKEY" "tailscale-funnel/TS_AUTHKEY" "deny" ]
    [ "-" "-" "restic/RESTIC_PASSWORD" "deny" ]
  ];

  flippableToAllow = [
    "openseo/DATAFORSEO_API_KEY"
    "openseo/GOOGLE_CLIENT_ID"
    "openseo/GOOGLE_CLIENT_SECRET"
  ];

  adguardHashDummy = "$2y$10$dummy.adguard.hash/with$dollars.and.slashes0123456789ab";

  tableSource = builtins.readFile (self + "/secrets/keys.tsv");
  tableLines = lib.filter (line: line != "") (lib.splitString "\n" tableSource);
  tableRows = map (lib.splitString tab) tableLines;

  templateOf = row: builtins.elemAt row 0;
  envKeyOf = row: builtins.elemAt row 1;
  secretOf = row: builtins.elemAt row 2;
  emptyOf = row: builtins.elemAt row 3;
  identityOf = row: lib.concatStringsSep tab (lib.take 3 row);

  rowsMatchOracle = oracle: row:
    identityOf oracle == identityOf row
    && (emptyOf oracle == emptyOf row || (builtins.elem (secretOf row) flippableToAllow && emptyOf row == "allow"));
  oracleRowPresent = oracle: builtins.any (rowsMatchOracle oracle) tableRows;
  isOracleIdentity = row: builtins.any (oracle: identityOf oracle == identityOf row) oracleRows;
  isPermittedExtra = row:
    templateOf row == "authentik.env"
    && lib.hasPrefix "authentik/AUTHENTIK_" (secretOf row)
    && builtins.match "[A-Z0-9_]+" (envKeyOf row) != null;
  extraRows = builtins.filter (row: !(isOracleIdentity row)) tableRows;

  forbidden = text: builtins.match ".*(HF_TOKEN|OLLAMA|PIHOLE).*" text != null;

  templateRows = builtins.filter (row: templateOf row != "-") tableRows;
  templates = lib.unique (map templateOf templateRows);
  rowsOf = template: builtins.filter (row: templateOf row == template) templateRows;
  secretNames = lib.unique (map secretOf tableRows);

  dummyFor = row:
    if emptyOf row == "allow" then ""
    else if secretOf row == "adguard/ADGUARD_PASSWORD_HASH" then adguardHashDummy
    else "dummy-" + builtins.replaceStrings [ "/" ] [ "-" ] (secretOf row);
  renderedLine = row: "${envKeyOf row}='${dummyFor row}'\n";
  expectedRendered = pkgs.runCommand "secrets-expected-rendered" { } (
    "mkdir $out\n"
    + lib.concatMapStrings (template: ''
      cp ${pkgs.writeText template (lib.concatMapStrings renderedLine (rowsOf template))} $out/${template}
    '') templates
  );

  sopsModule = self.inputs.sops-nix.nixosModules.sops;
  secretsModule = self + "/modules/secrets.nix";
  testModule = self + "/secrets/test-module.nix";

  baseModule = {
    fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
    boot.loader.grub.enable = false;
    system.stateVersion = "26.05";
  };

  production = lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      sopsModule
      self.nixosModules.options
      secretsModule
      baseModule
      { homelab.secrets.sopsFile = self + "/secrets/vm.yaml"; }
    ];
  };
  prodCfg = production.config;
  prodOpts = production.options;

  withTestModule = lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ sopsModule self.nixosModules.options secretsModule baseModule testModule ];
  };

  withoutSopsFile = lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ sopsModule self.nixosModules.options secretsModule baseModule ];
  };

  failingAssertions = system: builtins.filter (a: !a.assertion) system.config.assertions;
  withForbiddenSecret = name: production.extendModules {
    modules = [ { sops.secrets.${name} = { }; } ];
  };
  forbiddenSecretRefused = name:
    builtins.length (failingAssertions (withForbiddenSecret name)) > builtins.length (failingAssertions production);

  hashChar = builtins.fromJSON ''"\u0023"'';
  shellFallback = ":" + "-";
  ownedNixSources = [ "modules/secrets.nix" "secrets/test-module.nix" "tests/secrets.nix" ];
  sourceOf = name: builtins.readFile (self + "/${name}");

  evaluates = value: (builtins.tryEval (builtins.deepSeq value true)).success;

  expectations = {
    tableEndsWithNewline = lib.hasSuffix "\n" tableSource && !(lib.hasInfix "\n\n" tableSource);
    tableRowsHaveFourColumns = builtins.all (row: builtins.length row == 4) tableRows;
    tableEmptyColumnValid = builtins.all (row: builtins.elem (emptyOf row) [ "deny" "allow" ]) tableRows;
    tableSorted =
      let keyOf = row: "${templateOf row}${tab}${envKeyOf row}";
      in map keyOf templateRows == lib.sort lib.lessThan (map keyOf templateRows);
    tableNoDuplicateEnvKeys =
      let pairs = map (row: "${templateOf row}${tab}${envKeyOf row}") templateRows;
      in builtins.length pairs == builtins.length (lib.unique pairs);
    tableHasEveryOracleRow = builtins.all oracleRowPresent oracleRows;
    tableExtrasOnlyAuthentik = builtins.all isPermittedExtra extraRows;
    tableHasNoForbiddenKeys = !(forbidden tableSource);
    resticHasNoTemplate = builtins.all (row: secretOf row != "restic/RESTIC_PASSWORD" || templateOf row == "-") tableRows;

    keyFileIsHostPath = prodCfg.sops.age.keyFile == "/var/lib/sops-nix/key.txt";
    keyNotGenerated = prodCfg.sops.age.generateKey == false;
    noAgeSshKeys = prodCfg.sops.age.sshKeyPaths == [ ];
    noGnupgSshKeys = prodCfg.sops.gnupg.sshKeyPaths == [ ];
    defaultSopsFileIsOption = toString prodCfg.sops.defaultSopsFile == toString prodCfg.homelab.secrets.sopsFile;
    sopsFileIsPathWithoutDefault =
      prodOpts.homelab.secrets.sopsFile.type.name == "path" && !(prodOpts.homelab.secrets.sopsFile ? default);
    sopsFileRequired = !(evaluates withoutSopsFile.config.sops.defaultSopsFile);
    envDirReadOnly = prodOpts.homelab.secrets.envDir.readOnly or false;
    envDirIsRendered = prodCfg.homelab.secrets.envDir == "/run/secrets/rendered";
    templatesReadOnly = prodOpts.homelab.secrets.templates.readOnly or false;
    templatesMapToEnvDir =
      prodCfg.homelab.secrets.templates == lib.genAttrs templates (template: "/run/secrets/rendered/${template}");
    resticPasswordFileReadOnly = prodOpts.homelab.secrets.resticPasswordFile.readOnly or false;
    resticPasswordFileIsSecret =
      prodCfg.homelab.secrets.resticPasswordFile == prodCfg.sops.secrets."restic/RESTIC_PASSWORD".path;

    sopsSecretsMatchTable =
      lib.sort lib.lessThan (builtins.attrNames prodCfg.sops.secrets) == lib.sort lib.lessThan secretNames;
    sopsTemplatesMatchTable =
      lib.sort lib.lessThan (builtins.attrNames prodCfg.sops.templates) == lib.sort lib.lessThan templates;
    templatesOwnedByRoot = builtins.all (t: t.owner == "root" && t.mode == "0400") (builtins.attrValues prodCfg.sops.templates);
    productionAssertionsPass = failingAssertions production == [ ];

    hfTokenRefused = forbiddenSecretRefused "huggingface/HF_TOKEN";
    ollamaRefused = forbiddenSecretRefused "ollama/OLLAMA_BASE_URL";
    piholeRefused = forbiddenSecretRefused "pihole/PIHOLE_PASSWORD";

    testModuleUsesVmFile = toString withTestModule.config.homelab.secrets.sopsFile == toString (self + "/secrets/vm.yaml");
    testModuleProvidesTestKey = lib.hasInfix "test-age.key" (sourceOf "secrets/test-module.nix");
    productionNeverNamesTestKey = !(lib.hasInfix "test-age" (sourceOf "modules/secrets.nix"));

    noComments = builtins.all (name: !(lib.hasInfix hashChar (sourceOf name))) ownedNixSources;
    noShellFallbacks = builtins.all (name: !(lib.hasInfix shellFallback (sourceOf name))) ownedNixSources;
  };

  failed = builtins.attrNames (lib.filterAttrs (_: passed: !(evaluates passed) || !passed) expectations);
  verdict =
    if failed == [ ] then "ok" else throw "homelab secrets expectations failed: ${lib.concatStringsSep ", " failed}";
in
pkgs.testers.runNixOSTest {
  name = "secrets";
  nodes.machine = {
    imports = [ sopsModule self.nixosModules.options secretsModule testModule ];
    virtualisation.memorySize = 2048;
    users.users.probe.isNormalUser = true;
    environment.etc."homelab-secrets-eval".text = verdict;
  };
  testScript = { nodes, ... }: ''
    import json

    templates = json.loads('${builtins.toJSON templates}')
    env_keys = json.loads('${builtins.toJSON (lib.genAttrs templates (t: map envKeyOf (rowsOf t)))}')
    restic_file = "${nodes.machine.homelab.secrets.resticPasswordFile}"
    expected = "${expectedRendered}"

    machine.wait_for_unit("multi-user.target")
    assert machine.succeed("cat /etc/homelab-secrets-eval") == "ok"

    rendered = sorted(machine.succeed("ls -1 /run/secrets/rendered").split())
    assert rendered == sorted(templates), f"rendered files {rendered} != {sorted(templates)}"

    for template in templates:
        path = f"/run/secrets/rendered/{template}"
        mode_owner = machine.succeed(f"stat -c '%a %U' {path}").strip()
        assert mode_owner == "400 root", f"{template}: {mode_owner}"
        names = machine.succeed(f"sed 's/=.*//' {path}").split()
        assert names == env_keys[template], f"{template}: keys {names} != {env_keys[template]}"
        machine.fail(f"grep -qvE \"^[A-Z0-9_]+='[^']*'$\" {path}")
        machine.succeed(f"cmp {path} {expected}/{template}")
        machine.fail(f"runuser -u probe -- cat {path}")

    machine.fail("find -L /run/secrets /run/secrets.d | grep -E 'HF_TOKEN|OLLAMA|PIHOLE'")
    machine.fail("grep -rqE 'HF_TOKEN|OLLAMA|PIHOLE' /run/secrets.d")
    machine.fail("test -e /run/secrets/rendered/restic.env")

    mode_owner = machine.succeed(f"stat -L -c '%a %U' {restic_file}").strip()
    assert mode_owner == "400 root", f"restic password file: {mode_owner}"
    machine.succeed(f"test -s {restic_file}")
    assert machine.succeed(f"cat {restic_file}") == "dummy-restic-RESTIC_PASSWORD"
    machine.fail(f"runuser -u probe -- cat {restic_file}")
  '';
}
