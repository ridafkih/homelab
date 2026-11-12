{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.homelab.secrets;

  rows = map (line: lib.splitString "\t" line) (
    lib.filter (line: line != "") (lib.splitString "\n" (builtins.readFile ../secrets/keys.tsv))
  );
  rowOf = row: {
    template = builtins.elemAt row 0;
    envKey = builtins.elemAt row 1;
    secret = builtins.elemAt row 2;
  };
  table = map rowOf rows;
  templateRows = builtins.filter (row: row.template != "-") table;
  templateNames = lib.unique (map (row: row.template) templateRows);
  secretNames = lib.unique (map (row: row.secret) table);

  renderLine = row: "${row.envKey}='${config.sops.placeholder.${row.secret}}'\n";
  renderTemplate = name:
    lib.concatMapStrings renderLine (builtins.filter (row: row.template == name) templateRows);

  forbidden = name: builtins.match ".*(HF_TOKEN|OLLAMA|PIHOLE).*" name != null;
  forbiddenSecrets = builtins.filter forbidden (builtins.attrNames config.sops.secrets);
  templatesOutsideEnvDir =
    builtins.filter (path: !(lib.hasPrefix "${cfg.envDir}/" path)) (builtins.attrValues cfg.templates);
in
{
  options.homelab.secrets = {
    sopsFile = mkOption { type = types.path; };
    envDir = mkOption {
      type = types.str;
      readOnly = true;
      default = "/run/secrets/rendered";
    };
    templates = mkOption {
      type = types.attrsOf types.str;
      readOnly = true;
    };
    resticPasswordFile = mkOption {
      type = types.str;
      readOnly = true;
    };
  };

  config = {
    homelab.secrets = {
      templates = lib.genAttrs templateNames (name: config.sops.templates.${name}.path);
      resticPasswordFile = config.sops.secrets."restic/RESTIC_PASSWORD".path;
    };

    sops = {
      defaultSopsFile = cfg.sopsFile;
      age = {
        keyFile = "/var/lib/sops-nix/key.txt";
        generateKey = false;
        sshKeyPaths = [ ];
      };
      gnupg.sshKeyPaths = [ ];
      secrets = lib.genAttrs secretNames (_: { });
      templates = lib.genAttrs templateNames (name: {
        content = renderTemplate name;
        mode = "0400";
        owner = "root";
      });
    };

    assertions = [
      {
        assertion = forbiddenSecrets == [ ];
        message = "homelab.secrets: forbidden secrets declared: ${lib.concatStringsSep ", " forbiddenSecrets}";
      }
      {
        assertion = templatesOutsideEnvDir == [ ];
        message = "homelab.secrets: templates rendered outside ${cfg.envDir}: ${lib.concatStringsSep ", " templatesOutsideEnvDir}";
      }
    ];
  };
}
