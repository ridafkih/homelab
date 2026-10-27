{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.homelab.compose;
  checkout = config.homelab.checkoutDir;
  secrets = config.homelab.secrets;
  docker = config.virtualisation.docker.package;

  templateNames = lib.unique (
    builtins.filter (name: name != "" && name != "-") (
      map (line: builtins.head (lib.splitString "\t" line)) (lib.splitString "\n" (builtins.readFile ../secrets/keys.tsv))
    )
  );
  homelabTemplates = builtins.filter (name: name != "openseo.env") templateNames;

  projects = {
    homelab = {
      directory = checkout;
      envFiles = [ "${checkout}/homelab.env" ];
      templates = homelabTemplates;
      mounts = [ ];
    };
    openseo = {
      directory = "${checkout}/apps/openseo";
      envFiles = [ "${checkout}/apps/openseo/openseo.env" secrets.templates."openseo.env" ];
      templates = [ "openseo.env" ];
      mounts = [ ];
    };
    windows = {
      directory = "${checkout}/apps/windows";
      envFiles = [ ];
      templates = [ ];
      mounts = [ "/data/windows" ];
    };
  };

  unitOf = name: "${name}-compose.service";

  composeCommand = name: project: verb:
    lib.escapeShellArgs (
      [ "${docker}/bin/docker" "compose" "-p" name "--project-directory" project.directory "-f" "${project.directory}/compose.yaml" ]
      ++ lib.concatMap (file: [ "-f" "${file}" ]) (cfg.extraFiles.${name} or [ ])
      ++ lib.concatMap (file: [ "--env-file" file ]) project.envFiles
      ++ verb
    );

  upVerb = name: [ "up" "-d" "--pull" "missing" "--remove-orphans" ] ++ (cfg.services.${name} or [ ]);

  mkComposeUnit = name: project: {
    description = "Docker Compose project ${name}";
    wantedBy = [ "multi-user.target" ];
    after = [ "docker.service" "network-online.target" ];
    requires = [ "docker.service" ];
    wants = [ "network-online.target" ];
    path = [ docker ];
    environment = {
      HOMELAB_DATA_DIR = config.homelab.dataDir;
      HOMELAB_SECRETS_DIR = secrets.envDir;
    };
    reloadTriggers = cfg.extraFiles.${name} or [ ];
    unitConfig = {
      RequiresMountsFor = [ "/data" checkout ] ++ project.mounts;
      AssertPathExists = lib.unique (project.envFiles ++ map (template: secrets.templates.${template}) project.templates);
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = composeCommand name project (upVerb name);
      ExecReload = composeCommand name project (upVerb name);
      ExecStop = composeCommand name project [ "down" ];
      TimeoutStartSec = "1h";
      TimeoutStopSec = "5min";
    };
  };

  templateConsumers = lib.concatLists (
    lib.mapAttrsToList (name: project: map (template: { inherit template; unit = unitOf name; }) project.templates) projects
  );

  autoAllocatedPools = [
    { base = "172.17.0.0/16"; size = 16; }
    { base = "172.18.0.0/16"; size = 16; }
    { base = "172.21.0.0/16"; size = 16; }
    { base = "172.22.0.0/15"; size = 16; }
    { base = "172.24.0.0/14"; size = 16; }
    { base = "172.28.0.0/14"; size = 16; }
    { base = "192.168.0.0/16"; size = 20; }
  ];
in
{
  options.homelab.compose = {
    extraFiles = mkOption {
      type = types.attrsOf (types.listOf types.path);
      default = { };
    };
    services = mkOption {
      type = types.attrsOf (types.listOf types.str);
      default = { };
    };
  };

  config = {
    virtualisation.docker = {
      enable = true;
      package = pkgs.docker_29;
      enableOnBoot = true;
      daemon.settings = {
        log-driver = "json-file";
        log-opts = {
          max-size = "10m";
          max-file = "3";
        };
        default-address-pools = autoAllocatedPools;
      };
    };

    systemd.services = lib.mkMerge [
      (lib.mapAttrs' (name: project: lib.nameValuePair "${name}-compose" (mkComposeUnit name project)) projects)
      {
        homelab-compose.restartTriggers = [ config.homelab.trust.bundleSource ];
        openseo-compose = {
          after = [ (unitOf "homelab") ];
          requires = [ (unitOf "homelab") ];
        };
      }
    ];

    sops.templates = lib.mkMerge (
      map (consumer: { ${consumer.template}.reloadUnits = [ consumer.unit ]; }) templateConsumers
    );
  };
}
