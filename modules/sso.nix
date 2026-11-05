{ config, lib, pkgs, ... }:
let
  committedEnv = builtins.listToAttrs (
    map
      (line: let parts = lib.splitString "=" line; in lib.nameValuePair (builtins.head parts) (lib.concatStringsSep "=" (builtins.tail parts)))
      (builtins.filter (line: line != "") (lib.splitString "\n" (builtins.readFile ../homelab.env)))
  );
  domain = committedEnv.CADDY_DOMAIN;
  hostOf = name: "${name}.${domain}";
  urlOf = name: "https://${hostOf name}";

  pocketIdPort = 1411;
  tinyauthPort = 3820;
  caddyNetwork = "172.20.0.0/16";
  pocketIdUrl = urlOf "id";
  pocketIdLocal = "http://127.0.0.1:${toString pocketIdPort}";
  tinyauthUrl = urlOf "auth";

  secretPath = name: config.sops.secrets."pocket-id/${name}".path;
  clientSecretPath = id: secretPath "CLIENT_SECRET_${lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] id)}";

  groups = [
    { name = "admins"; friendlyName = "Admins"; }
    { name = "media"; friendlyName = "Media"; }
  ];

  client = id: name: callbackURLs: groups: {
    inherit id name callbackURLs groups;
    logoutCallbackURLs = [ ];
    isPublic = false;
    pkceEnabled = id != "tailscale";
  };

  clients = [
    (client "tailscale" "Tailscale" [ "https://login.tailscale.com/a/oauth_response" ] [ ])
    (client "tinyauth" "Tinyauth" [ "${tinyauthUrl}/api/oauth/callback/pocketid" ] [ ])
    (client "jellyfin" "Jellyfin" [ "${urlOf "jellyfin"}/sso/OID/redirect/pocketid" ] [ "media" ])
    (client "seafile" "Seafile" [ "${urlOf "seafile"}/oauth/callback/" ] [ ])
    (client "open-webui" "Open WebUI" [ "${urlOf "open-webui"}/oauth/oidc/callback" ] [ "admins" ])
    (client "qui" "qui" [ "${urlOf "qui"}/api/auth/oidc/callback" ] [ "admins" ])
  ];

  confidentialClients = map (entry: entry.id) (builtins.filter (entry: !entry.isPublic) clients);

  spec = pkgs.writeText "pocket-id-directory.json" (builtins.toJSON { inherit groups clients; });

  secretsDir = "/run/pocket-id-provision";

  provision = pkgs.writeShellApplication {
    name = "pocket-id-provision";
    runtimeInputs = [ pkgs.curl pkgs.jq ];
    text = builtins.readFile ./pocket-id-provision.sh;
  };

  invite = pkgs.writeShellApplication {
    name = "pocket-id-invite";
    runtimeInputs = [ pkgs.curl pkgs.jq ];
    text = builtins.replaceStrings [ "@api@" "@appUrl@" "@apiKeyFile@" ] [ "${pocketIdLocal}/api" pocketIdUrl (secretPath "STATIC_API_KEY") ] (
      builtins.readFile ./pocket-id-invite.sh
    );
  };

  gatedApps = {
    sonarr = "admins";
    radarr = "admins";
    prowlarr = "admins";
    bazarr = "admins";
    qbittorrent = "admins";
    adguard = "admins";
    signoz = "admins";
    open-seo = "admins";
    windows = "admins";
    jellyseerr = "media";
  };

  tinyauthConfig = pkgs.writeText "tinyauth.json" (builtins.toJSON {
    appUrl = tinyauthUrl;
    labelProvider = "none";
    auth = {
      secureCookie = true;
      trustedProxies = [ caddyNetwork ];
      sessionExpiry = 7 * 86400;
      acls.policy = "deny";
    };
    oauth = {
      autoRedirect = "pocketid";
      providers.pocketid = {
        name = "Pocket ID";
        clientId = "tinyauth";
        clientSecretFile = "/run/credentials/tinyauth.service/client-secret";
        authUrl = "${pocketIdUrl}/authorize";
        tokenUrl = "${pocketIdLocal}/api/oidc/token";
        userinfoUrl = "${pocketIdLocal}/api/oidc/userinfo";
        redirectUrl = "${tinyauthUrl}/api/oauth/callback/pocketid";
        scopes = [ "openid" "email" "profile" "groups" ];
      };
    };
    apps = lib.mapAttrs (name: group: {
      config.domain = hostOf name;
      oauth.groups = group;
    }) gatedApps;
  });

in
{
  services.pocket-id = {
    enable = true;
    settings = {
      APP_URL = pocketIdUrl;
      TRUST_PROXY = true;
      ANALYTICS_DISABLED = true;
      PORT = pocketIdPort;
    };
    credentials = {
      ENCRYPTION_KEY = secretPath "ENCRYPTION_KEY";
      STATIC_API_KEY = secretPath "STATIC_API_KEY";
    };
  };

  services.tinyauth = {
    enable = true;
    settings = {
      APPURL = tinyauthUrl;
      SERVER_PORT = tinyauthPort;
      CONFIGFILE = "${tinyauthConfig}";
      AUTH_TRUSTEDPROXIES = caddyNetwork;
    };
  };

  systemd.services.tinyauth = {
    after = [ "pocket-id.service" ];
    wants = [ "pocket-id.service" ];
    serviceConfig.LoadCredential = [ "client-secret:${clientSecretPath "tinyauth"}" ];
  };

  systemd.services.pocket-id-provision = {
    description = "Declare the Pocket ID groups and OIDC clients";
    after = [ "pocket-id.service" ];
    requires = [ "pocket-id.service" ];
    wantedBy = [ "multi-user.target" ];
    restartTriggers = [ spec ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      LoadCredential = [ "api-key:${secretPath "STATIC_API_KEY"}" ]
        ++ map (id: "${id}:${clientSecretPath id}") confidentialClients;
      ExecStart = "${lib.getExe provision} ${spec} ${pocketIdLocal}/api %d/api-key %d";
      DynamicUser = true;
    };
  };

  environment.systemPackages = [ invite ];

  networking.firewall.extraCommands = ''
    iptables -I nixos-fw -s ${caddyNetwork} -p tcp -m multiport --dports ${toString pocketIdPort},${toString tinyauthPort} -j nixos-fw-accept
  '';
}
