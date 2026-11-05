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
  dockerNetworks = "172.16.0.0/12";
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
    pkceEnabled = id == "jellyfin";
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

  seafileOauth = pkgs.writeShellApplication {
    name = "seafile-oauth";
    runtimeInputs = [ pkgs.gnugrep pkgs.coreutils ];
    text = ''
      readonly settings=$1
      readonly line="from seahub_oauth_settings import *"
      if ! grep -qxF "$line" "$settings"; then
        printf '\n%s\n' "$line" >> "$settings"
        echo "added the Pocket ID import to $settings"
      fi
    '';
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
    server = {
      address = "0.0.0.0";
      port = tinyauthPort;
    };
    auth = {
      secureCookie = true;
      trustedProxies = [ dockerNetworks ];
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

  jellyfinPlugin = pkgs.fetchzip {
    url = "https://github.com/K0lin/jellyfin-plugin-sso/releases/download/v5.1.1/sso-authentication_5.1.1.zip";
    hash = "sha256-QYzyg8pJvsLvmJbgOujhms7vY7BmLlqgcndxqNGyJcI=";
    stripRoot = false;
  };

  jellyfinConfig = config.homelab.dataDir + "/jellyfin/config";

  jellyfinSsoTemplate = pkgs.writeText "SSO-Auth.xml" ''
    <?xml version="1.0" encoding="utf-8"?>
    <PluginConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
      <SamlConfigs />
      <OidConfigs>
        <item>
          <key><string>pocketid</string></key>
          <value>
            <PluginConfiguration>
              <OidEndpoint>${pocketIdUrl}</OidEndpoint>
              <OidClientId>jellyfin</OidClientId>
              <OidSecret>@CLIENT_SECRET@</OidSecret>
              <Enabled>true</Enabled>
              <EnableAuthorization>false</EnableAuthorization>
              <EnableAllFolders>false</EnableAllFolders>
              <EnabledFolders />
              <AdminRoles />
              <PreserveAdminPermissions>true</PreserveAdminPermissions>
              <Roles />
              <EnableFolderRoles>false</EnableFolderRoles>
              <EnableLiveTvRoles>false</EnableLiveTvRoles>
              <EnableLiveTv>false</EnableLiveTv>
              <EnableLiveTvManagement>false</EnableLiveTvManagement>
              <LiveTvRoles />
              <LiveTvManagementRoles />
              <FolderRoleMapping />
              <RoleClaim>groups</RoleClaim>
              <OidScopes />
              <OverrideDefaultScopes>false</OverrideDefaultScopes>
              <SchemeOverride>https</SchemeOverride>
              <NewPath>true</NewPath>
              <CanonicalLinks />
              <DefaultUsernameClaim>preferred_username</DefaultUsernameClaim>
              <DisableHttps>false</DisableHttps>
              <DisablePushedAuthorization>false</DisablePushedAuthorization>
              <DoNotValidateEndpoints>false</DoNotValidateEndpoints>
              <DoNotValidateIssuerName>false</DoNotValidateIssuerName>
              <DoNotLoadProfile>false</DoNotLoadProfile>
            </PluginConfiguration>
          </value>
        </item>
      </OidConfigs>
    </PluginConfiguration>
  '';

  jellyfinSignInButton = lib.escapeXML ''
    <form action="${urlOf "jellyfin"}/sso/OID/start/pocketid" method="get"><button class="raised block emby-button button-submit" type="submit">Sign in with Pocket ID</button></form>
  '';

  jellyfinBranding = pkgs.writeText "branding.xml" ''
    <?xml version="1.0" encoding="utf-8"?>
    <BrandingOptions xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
      <LoginDisclaimer>${lib.trim jellyfinSignInButton}</LoginDisclaimer>
      <CustomCss />
      <SplashscreenEnabled>false</SplashscreenEnabled>
    </BrandingOptions>
  '';

  jellyfinSso = pkgs.writeShellApplication {
    name = "jellyfin-sso";
    runtimeInputs = [ pkgs.coreutils pkgs.diffutils pkgs.gawk config.virtualisation.docker.package ];
    text = builtins.readFile ./jellyfin-sso.sh;
  };
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
      AUTH_TRUSTEDPROXIES = dockerNetworks;
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

  systemd.services.jellyfin-sso = {
    description = "Install and configure the Jellyfin SSO plugin";
    before = [ "homelab-compose.service" ];
    wantedBy = [ "multi-user.target" "homelab-compose.service" ];
    after = [ "docker.service" ];
    restartTriggers = [ jellyfinPlugin jellyfinSsoTemplate jellyfinBranding ];
    unitConfig.RequiresMountsFor = [ config.homelab.dataDir ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.escapeShellArgs [
        (lib.getExe jellyfinSso)
        jellyfinPlugin
        "${jellyfinConfig}/plugins/SSO Authentication_5.1.1"
        jellyfinSsoTemplate
        "${jellyfinConfig}/plugins/configurations/SSO-Auth.xml"
        (clientSecretPath "jellyfin")
        jellyfinBranding
        "${jellyfinConfig}/config/branding.xml"
        "${toString config.homelab.uid}:${toString config.homelab.gid}"
      ];
    };
  };

  systemd.services.seafile-oauth = {
    description = "Load the Pocket ID settings into Seahub";
    before = [ "homelab-compose.service" ];
    wantedBy = [ "multi-user.target" "homelab-compose.service" ];
    unitConfig.RequiresMountsFor = [ committedEnv.SEAFILE_DATA_PATH ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.escapeShellArgs [ (lib.getExe seafileOauth) "${committedEnv.SEAFILE_DATA_PATH}/seafile/conf/seahub_settings.py" ];
    };
  };

  environment.systemPackages = [ invite ];

  networking.firewall.extraCommands = ''
    iptables -I nixos-fw -s ${dockerNetworks} -p tcp -m multiport --dports ${toString pocketIdPort},${toString tinyauthPort} -j nixos-fw-accept
  '';
}
