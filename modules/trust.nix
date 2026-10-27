{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  etcName = "homelab-ca/certs/ca-certificates.crt";
  bundle = builtins.replaceStrings [ "/ca-bundle.crt" ] [ "/ca-no-trust-rules-bundle.crt" ] config.security.pki.caBundle;
in
{
  options.homelab.trust = {
    bundleEtcPath = mkOption {
      type = types.str;
      readOnly = true;
      default = "/etc/${etcName}";
    };
    bundleSource = mkOption {
      type = types.str;
      readOnly = true;
      default = bundle;
    };
  };

  config.environment.etc.${etcName} = {
    source = config.homelab.trust.bundleSource;
    mode = "0444";
  };
}
