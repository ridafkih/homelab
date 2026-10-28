{ pkgs, self, lib }:
let
  modulePath = self + "/modules/docker-apps.nix";
  dockerAppsModule =
    if builtins.pathExists modulePath then modulePath else throw "modules/docker-apps.nix is missing";

  archFiles = [
    "host/etc/docker/daemon.json"
    "host/etc/systemd/system/jellyfin-ensure.service"
  ];
  ownedSources = [ "modules/docker-apps.nix" "tests/compose.nix" ];
  sourceOf = name: let path = self + "/${name}"; in if builtins.pathExists path then builtins.readFile path else "";
  hashChar = builtins.fromJSON ''"\u0023"'';
  shellFallback = ":" + "-";

  host = self.nixosConfigurations.homelab.extendModules {
    modules = [ { homelab.secrets.sopsFile = lib.mkForce (self + "/secrets/vm.yaml"); } ];
  };
  cfg = host.config;
  opts = host.options;
  checkout = cfg.homelab.checkoutDir;
  envDir = cfg.homelab.secrets.envDir;

  projects = [ "homelab" "openseo" "windows" ];
  unitName = project: "${project}-compose.service";
  serviceOf = project: cfg.systemd.services."${project}-compose" or { };
  service = project: (serviceOf project).serviceConfig or { };
  unitCfg = project: (serviceOf project).unitConfig or { };
  field = project: name: (serviceOf project).${name} or [ ];

  listOf = value:
    if builtins.isList value then map toString value
    else if value == null then [ ]
    else lib.filter (item: item != "") (lib.splitString " " (toString value));
  includesAll = wanted: present: builtins.all (item: builtins.elem item present) wanted;
  isTrue = value: value == true || value == "yes" || value == "true";

  templateNames = builtins.attrNames cfg.homelab.secrets.templates;
  homelabTemplates = builtins.filter (name: name != "openseo.env") templateNames;
  templatePath = name: cfg.homelab.secrets.templates.${name};
  templateUnits = name:
    let template = cfg.sops.templates.${name};
    in (template.reloadUnits or [ ]) ++ (template.restartUnits or [ ]);

  expectedAsserts = {
    homelab = [ "${checkout}/homelab.env" ] ++ map templatePath homelabTemplates;
    openseo = [ "${checkout}/apps/openseo/openseo.env" (templatePath "openseo.env") ];
    windows = [ ];
  };

  daemon = cfg.virtualisation.docker.daemon.settings;
  extraFilesOpt = opts.homelab.compose.extraFiles or null;
  servicesOpt = opts.homelab.compose.services or null;
  compose = cfg.homelab.compose or null;

  perProject = project: {
    "${project}UnitExists" = cfg.systemd.services ? "${project}-compose";
    "${project}Oneshot" = (service project).Type or null == "oneshot";
    "${project}RemainsAfterExit" = isTrue ((service project).RemainAfterExit or false);
    "${project}StartTimeoutOneHour" = builtins.elem ((service project).TimeoutStartSec or null) [ "1h" "60min" "3600" 3600 ];
    "${project}StopTimeoutFiveMinutes" = builtins.elem ((service project).TimeoutStopSec or null) [ "5min" "5m" "300" 300 ];
    "${project}WantedAtBoot" = builtins.elem "multi-user.target" (field project "wantedBy");
    "${project}AfterDocker" = includesAll [ "docker.service" "network-online.target" ] (field project "after");
    "${project}RequiresDocker" = builtins.elem "docker.service" (field project "requires");
    "${project}WantsNetworkOnline" = builtins.elem "network-online.target" (field project "wants");
    "${project}RequiresMounts" = includesAll [ "/data" checkout ] (listOf ((unitCfg project).RequiresMountsFor or [ ]));
    "${project}AssertsEnvFiles" =
      lib.sort lib.lessThan (listOf ((unitCfg project).AssertPathExists or [ ]))
      == lib.sort lib.lessThan expectedAsserts.${project};
    "${project}DataDirEnv" = ((serviceOf project).environment or { }).HOMELAB_DATA_DIR or null == cfg.homelab.dataDir;
    "${project}SecretsDirEnv" = ((serviceOf project).environment or { }).HOMELAB_SECRETS_DIR or null == envDir;
    "${project}DockerOnPath" =
      builtins.any (package: (package.outPath or null) == cfg.virtualisation.docker.package.outPath) (field project "path");
    "${project}NoReloadIfChanged" = !((serviceOf project).reloadIfChanged or false);
    "${project}HasStop" = (service project) ? ExecStop;
    "${project}HasReload" = (service project) ? ExecReload;
  };

  expectations = lib.foldl' (acc: project: acc // perProject project) { } projects // {
    moduleExists = builtins.pathExists modulePath;
    archFilesDeleted = builtins.all (file: !(builtins.pathExists (self + "/${file}"))) archFiles;

    dockerEnabled = cfg.virtualisation.docker.enable;
    dockerOnBoot = cfg.virtualisation.docker.enableOnBoot;
    dockerIs29 = cfg.virtualisation.docker.package.outPath == host.pkgs.docker_29.outPath;
    dockerNoAutoPrune = !cfg.virtualisation.docker.autoPrune.enable;
    daemonJsonFileLogs = (daemon.log-driver or null) == "json-file";
    daemonLogRotation = (daemon.log-opts or null) == { max-size = "10m"; max-file = "3"; };
    daemonNoDns = !(daemon ? dns);
    daemonNoRuntimes = !(daemon ? runtimes);
    daemonBridgeIsHostGateway = (daemon.bip or null) == "172.17.0.1/16";
    daemonPoolsSkipFixedSubnets =
      let bases = map (pool: pool.base) (daemon.default-address-pools or [ ]);
      in bases != [ ] && !(builtins.elem "172.19.0.0/16" bases) && !(builtins.elem "172.20.0.0/16" bases);
    hostGatewayMismatchFailsEval =
      let
        moved = host.extendModules { modules = [ { virtualisation.docker.daemon.settings.bip = lib.mkForce "172.30.0.1/16"; } ]; };
        failing = config: builtins.length (builtins.filter (a: !a.assertion) config.assertions);
      in
      failing moved.config > failing cfg;

    extraFilesType =
      extraFilesOpt != null
      && extraFilesOpt.type.name == "attrsOf"
      && extraFilesOpt.type.nestedTypes.elemType.name == "listOf"
      && extraFilesOpt.type.nestedTypes.elemType.nestedTypes.elemType.name == "path";
    servicesType =
      servicesOpt != null
      && servicesOpt.type.name == "attrsOf"
      && servicesOpt.type.nestedTypes.elemType.name == "listOf"
      && servicesOpt.type.nestedTypes.elemType.nestedTypes.elemType.name == "str";
    extraFilesDefaultEmpty = extraFilesOpt != null && extraFilesOpt.default == { };
    servicesDefaultEmpty = servicesOpt != null && servicesOpt.default == { };
    productionHasNoOverrides = compose != null && compose.extraFiles == { } && compose.services == { };

    openseoAfterHomelab = builtins.elem "homelab-compose.service" (field "openseo" "after");
    openseoRequiresHomelab = builtins.elem "homelab-compose.service" (field "openseo" "requires");
    homelabRestartsOnCaBundle = builtins.elem cfg.homelab.trust.bundleSource (map toString (field "homelab" "restartTriggers"));
    homelabTemplatesNotifyHomelab = builtins.all (name: builtins.elem "homelab-compose.service" (templateUnits name)) homelabTemplates;
    openseoTemplateNotifiesOpenseo = builtins.elem "openseo-compose.service" (templateUnits "openseo.env");

    noComments = builtins.all (name: !(lib.hasInfix hashChar (sourceOf name))) ownedSources;
    noShellFallbacks = builtins.all (name: !(lib.hasInfix shellFallback (sourceOf name))) ownedSources;
  };

  evaluates = value: (builtins.tryEval (builtins.deepSeq value true)).success;
  holds = value: let result = builtins.tryEval value; in result.success && result.value == true;
  failed = lib.attrNames (lib.filterAttrs (_: passed: !(evaluates passed) || !(holds passed)) expectations);
  gate = value:
    if failed == [ ] then value else throw "homelab compose expectations failed: ${lib.concatStringsSep ", " failed}";

  upArgs = "up -d --pull missing --remove-orphans";
  commandChecks = {
    homelab = {
      present = [
        "-p homelab"
        "--project-directory ${checkout}"
        "-f ${checkout}/compose.yaml"
        "--env-file ${checkout}/homelab.env"
      ];
      absent = [ "homelab-test" ];
    };
    openseo = {
      present = [
        "-p openseo"
        "--project-directory ${checkout}/apps/openseo"
        "-f ${checkout}/apps/openseo/compose.yaml"
        "--env-file ${checkout}/apps/openseo/openseo.env --env-file ${templatePath "openseo.env"}"
      ];
      absent = [ "homelab-test" ];
    };
    windows = {
      present = [
        "-p windows"
        "--project-directory ${checkout}/apps/windows"
        "-f ${checkout}/apps/windows/compose.yaml"
      ];
      absent = [ "--env-file" "homelab-test" ];
    };
  };

  checkUnit = project:
    let
      checks = commandChecks.${project};
      presentLines = lib.concatMapStrings (needle: ''
        need start ${lib.escapeShellArg needle}
        need stop ${lib.escapeShellArg needle}
      '') checks.present;
      absentLines = lib.concatMapStrings (needle: ''
        refuse start ${lib.escapeShellArg needle}
        refuse stop ${lib.escapeShellArg needle}
      '') checks.absent;
    in
    ''
      unit=$(find ${cfg.systemd.units.${unitName project}.unit}/ -name ${unitName project} | head -n1)
      test -n "$unit" || fail "${project}: unit file missing"
      expand "$unit" ExecStart > start
      expand "$unit" ExecReload > reload
      expand "$unit" ExecStop > stop
      current=${project}
      ${presentLines}
      ${absentLines}
      need start ${lib.escapeShellArg upArgs}
      need reload ${lib.escapeShellArg upArgs}
      need stop " down"
      refuse stop " up "
    '';

  units = pkgs.runCommand "compose-units" { } ''
    fail() { echo "compose units: $*" >&2; exit 1; }
    expand() {
      grep "^$2=" "$1" | sed "s|^$2=||" > raw || true
      test -s raw || fail "$current: $2 missing"
      {
        cat raw
        for item in $(grep -o '/nix/store/[^ ;]*' raw); do
          if [ -f "$item" ] && grep -Iq . "$item"; then cat "$item"; fi
        done
      } | tr '\n\\' '  ' | tr -d "'\"" | tr -s ' '
      echo
    }
    need() { grep -qF -- "$2" "$1" || fail "$current: $1 lacks: $2"; }
    refuse() { if grep -qF -- "$2" "$1"; then fail "$current: $1 must not contain: $2"; fi; }
    ${lib.concatMapStrings checkUnit projects}
    echo ok > $out
  '';

  caddyImage = pkgs.dockerTools.pullImage {
    imageName = "ghcr.io/caddybuilds/caddy-cloudflare";
    imageDigest = "sha256:9c398a17f826530b99e0a68e63ba85f341ddbadc9c2f23668a1aa8f58ce33fb8";
    hash = "sha256-1HdWllpu8Z00VfHTDMK1fPrsORVPiE4kn4T6fo51NUY=";
    finalImageName = "homelab-test/caddy";
    finalImageTag = "pinned";
    os = "linux";
    arch = "amd64";
  };
  adguardImage = pkgs.dockerTools.pullImage {
    imageName = "adguard/adguardhome";
    imageDigest = "sha256:aba9e3bf0613be3ba3755e1fc311b126e2c24bec25e18b6483894a88283074f0";
    hash = "sha256-cdRGtBHzmZUwFgzOVpta1aRSFWpBq+/ZGejrMMiOtv4=";
    finalImageName = "homelab-test/adguardhome";
    finalImageTag = "pinned";
    os = "linux";
    arch = "amd64";
  };
  alpineImage = pkgs.dockerTools.pullImage {
    imageName = "alpine";
    imageDigest = "sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a";
    hash = "sha256-4UYmxIqDZ+oy6vBGh5Q39BLOFO/x0NNpwG6KvVkfK5I=";
    finalImageName = "homelab-test/alpine";
    finalImageTag = "pinned";
    os = "linux";
    arch = "amd64";
  };

  offlineOverride = pkgs.writeText "compose-offline.yaml" (builtins.toJSON {
    services = {
      caddy = {
        image = "homelab-test/caddy:pinned";
        pull_policy = "never";
      };
      adguard-init = {
        image = "homelab-test/alpine:pinned";
        pull_policy = "never";
      };
      adguard = {
        image = "homelab-test/adguardhome:pinned";
        pull_policy = "never";
      };
    };
  });

  dataDir = "/var/lib/homelab-test";
  vmCheckout = "${self}";
  missingTemplate = "caddy.env";

  vm = pkgs.testers.runNixOSTest {
    name = "compose";
    nodes.machine = { config, ... }: {
      imports = [
        self.inputs.sops-nix.nixosModules.sops
        self.nixosModules.options
        (self + "/modules/secrets.nix")
        (self + "/secrets/test-module.nix")
        (self + "/modules/trust.nix")
        dockerAppsModule
      ];
      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 4096;
      homelab.checkoutDir = vmCheckout;
      homelab.dataDir = dataDir;
      homelab.compose.extraFiles.homelab = [ offlineOverride ];
      homelab.compose.services.homelab = [ "caddy" "adguard-init" "adguard" ];
      environment.systemPackages = [ pkgs.curl pkgs.dnsutils ];
      systemd.services.openseo-compose.wantedBy = lib.mkForce [ ];
      systemd.services.windows-compose.wantedBy = lib.mkForce [ ];

      systemd.services.homelab-test-images = {
        requiredBy = [ "homelab-compose.service" ];
        before = [ "homelab-compose.service" ];
        after = [ "docker.service" ];
        requires = [ "docker.service" ];
        path = [ config.virtualisation.docker.package ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          docker load -i ${caddyImage}
          docker load -i ${adguardImage}
          docker load -i ${alpineImage}
        '';
      };
    };
    testScript = { nodes, ... }: ''
      template = "${nodes.machine.homelab.secrets.templates.${missingTemplate}}"
      label = "{{index .Config.Labels \"com.docker.compose.project\"}}"
      workdir = "{{index .Config.Labels \"com.docker.compose.project.working_dir\"}}"

      def caddy_answers():
          code = machine.wait_until_succeeds(
              "curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1/", timeout=180
          ).strip()
          assert code.isdigit() and code != "000", f"caddy gave no HTTP status: {code}"

      def adguard_answers():
          machine.wait_until_succeeds(
              "dig +time=15 +tries=1 @127.0.0.1 example.com A | grep -q 'status:'", timeout=180
          )

      machine.wait_for_unit("multi-user.target")
      machine.succeed("docker compose version")

      machine.wait_for_unit("homelab-compose.service")
      assert machine.succeed("systemctl is-active homelab-compose.service").strip() == "active"

      for container in ["caddy", "adguardhome"]:
          project = machine.succeed(f"docker inspect -f '{label}' {container}").strip()
          assert project == "homelab", f"{container} project label is {project}"
          directory = machine.succeed(f"docker inspect -f '{workdir}' {container}").strip()
          assert directory == "${vmCheckout}", f"{container} working dir is {directory}"

      caddy_answers()
      adguard_answers()

      docker0 = machine.succeed("ip -4 -o addr show dev docker0").split()[3]
      assert docker0 == "172.17.0.1/16", f"docker0 is {docker0}, but homelab.env CADDY_HOST_MACHINE_HOSTNAME is 172.17.0.1"

      rendered = machine.succeed("cat ${dataDir}/adguardhome/conf/AdGuardHome.yaml")
      assert "dummy-adguard-ADGUARD_USER" in rendered, "adguard-init did not render the test user"
      assert "$2y$10$dummy.adguard.hash/with$dollars.and.slashes0123456789ab" in rendered, "adguard-init did not render the test hash"

      machine.succeed("systemctl stop homelab-compose.service")
      machine.fail("docker inspect caddy")
      machine.succeed(f"mv {template} /root/held-template")
      machine.fail("systemctl start homelab-compose.service")
      machine.fail("systemctl is-active homelab-compose.service")
      machine.fail("docker inspect caddy")
      journal = machine.succeed("journalctl -b --no-pager -u homelab-compose.service")
      status = machine.execute("systemctl status --no-pager --full homelab-compose.service")[1]
      assert template in journal + status, f"neither the journal nor systemctl status names {template}: {status}"

      machine.succeed(f"mv /root/held-template {template}")
      machine.succeed("systemctl start homelab-compose.service")
      assert machine.succeed("systemctl is-active homelab-compose.service").strip() == "active"
      caddy_answers()
      adguard_answers()
    '';
  };
in
pkgs.runCommand "compose" {
  units = gate units;
  vm = gate vm;
} ''
  echo ok > $out
''
