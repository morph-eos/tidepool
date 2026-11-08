# Single sign-on (ADR 0011, 0020): Nextcloud's oidc app is the identity provider. The clients (the programs that log in through it) are declared here and registered after Nextcloud's setup,
# and each program's own side is configured from the same declaration. Today: Immich, and Floppy when it runs. Off by default (tidepool.sso.enable): it needs Nextcloud and the clients' secrets.
# This is an exception to P1 (docs/exceptions.md, entry 4): the oidc app has no declarative setting for its clients, only the `occ oidc:create` command.
{ config, lib, pkgs, ... }:
let
  cfg = config.tidepool.sso;
  d = config.tidepool.domain;
  occ = "${config.services.nextcloud.occ}/bin/nextcloud-occ";
  json = builtins.toJSON;
  floppy = config.tidepool.services.floppy.enable;
  providerId = "sso";   # the name in Floppy's callback address, /accounts/oidc/<providerId>/login/callback/
  # `occ oidc:create` wants a client id of 32 to 64 printable characters: a stable one made from the domain
  generated = n: "${n}-" + builtins.substring 0 32 (builtins.hashString "sha256" "${n}-${d}");
  idOf = n: if (cfg.clients.${n}.clientId or null) != null then cfg.clients.${n}.clientId else generated n;
  register = id: c: ''
    secret=$(cat ${config.sops.secrets.${c.secret}.path})
    want_uris=${lib.escapeShellArg (json c.redirectUris)}
    have=$(${occ} oidc:list | ${pkgs.jq}/bin/jq -c --arg id ${lib.escapeShellArg id} '[.[] | select(.client_id == $id)] | .[0] // empty | {s: .client_secret, u: .redirect_uris}')
    if [ "$have" != "$(${pkgs.jq}/bin/jq -nc --arg s "$secret" --argjson u "$want_uris" '{s: $s, u: $u}')" ]; then
      ${occ} oidc:remove ${lib.escapeShellArg id} >/dev/null 2>&1 || true
      ${occ} oidc:create ${lib.escapeShellArg c.name} ${lib.escapeShellArgs c.redirectUris} --client_id=${lib.escapeShellArg id} --client_secret="$secret" --type=confidential --flow=code --algorithm=RS256 >/dev/null
      echo "registered ${c.name}"
    fi
  '';
  jf = cfg.jellyfin.enable && config.tidepool.services.jellyfin.enable;
  # SSO Authentication, a plugin of Jellyfin's catalog, at the release the settings below were written for: the files of its zip, which is what Jellyfin finds in a folder of its plugin directory
  ssoPlugin = pkgs.fetchzip { url = "https://github.com/K0lin/jellyfin-plugin-sso/releases/download/v5.1.1/sso-authentication_5.1.1.zip"; hash = "sha256-QYzyg8pJvsLvmJbgOujhms7vY7BmLlqgcndxqNGyJcI="; stripRoot = false; };
  pluginsDir = "/srv/data/jellyfin/config/plugins";
  jellyfinSso = pkgs.writeShellScript "jellyfin-sso" ''
    set -u
    export PATH=${lib.makeBinPath [ pkgs.xmlstarlet pkgs.perl pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.bash ]}
    ${lib.optionalString cfg.jellyfin.installPlugin ''
    set -- "${pluginsDir}"/"SSO Authentication_"*
    if [ ! -e "$1" ]; then
      mkdir -p "${pluginsDir}/SSO Authentication_5.1.1" && cp ${ssoPlugin}/* "${pluginsDir}/SSO Authentication_5.1.1/" && chmod -R u+w "${pluginsDir}/SSO Authentication_5.1.1" && echo "installed the SSO Authentication plugin"
    fi
    ''}
    # the plugin's settings follow the declaration (the client's id and secret, the address); what is in the file besides those four fields, the links between Nextcloud's users and Jellyfin's among them, stays. A failure is told and does not stop Jellyfin
    ${../jellyfin/sso/sso-config.sh} --config-dir ${pluginsDir}/configurations --provider ${cfg.jellyfin.provider} --endpoint https://cloud.${d} --client-id ${lib.escapeShellArg (idOf "jellyfin")} --secret-file ${config.sops.secrets.${cfg.clients.jellyfin.secret}.path} --adopt || echo "the plugin's settings were not written (exit $?)"
  '';
  script = pkgs.writeShellScript "nextcloud-oidc-clients" ("set -euo pipefail\n" + lib.concatStrings (lib.mapAttrsToList (n: c: register (idOf n) c) cfg.clients));
in
{
  options.tidepool.sso = {
    enable = lib.mkEnableOption "Nextcloud as the single sign-on of the other services";
    jellyfin = {
      enable = lib.mkEnableOption "Jellyfin's sign-in through Nextcloud: the client declared here, the plugin's settings written before each start, the button on the login page (nixos/jellyfin/sso/README.md)";
      provider = lib.mkOption { type = lib.types.strMatching "[A-Za-z0-9_-]+"; default = "nextcloud"; description = "The provider's name in the plugin's addresses: the button goes to /sso/OID/start/<provider> and Nextcloud returns the user to /sso/OID/redirect/<provider>."; };
      installPlugin = lib.mkOption { type = lib.types.bool; default = true; description = "Put the plugin (a pinned release of SSO Authentication) in Jellyfin's plugin directory when there is none there. A plugin that is already installed, in any version, is left as it is."; };
    };
    clients = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule { options = {
        name = lib.mkOption { type = lib.types.str; description = "The client's name, as the identity provider shows it."; };
        redirectUris = lib.mkOption { type = lib.types.listOf lib.types.str; };
        secret = lib.mkOption { type = lib.types.str; description = "The sops secret that holds the client secret (32 to 64 printable characters, no colon)."; };
        clientId = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "The client's id (32 to 64 printable characters). Null: one made from the client's name and the domain. Set it to adopt a client that already exists in Nextcloud under another id, with its secret in sops: the login that works keeps working."; };
      }; });
      default = { };
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [ { assertion = config.services.nextcloud.enable; message = "tidepool.sso.enable needs Nextcloud"; } ];
    tidepool.sso.clients.immich = { name = "Immich"; redirectUris = [ "https://photos.${d}/auth/login" "https://photos.${d}/user-settings" "app.immich:///oauth-callback" ]; secret = "immich-oauth-secret"; };
    tidepool.sso.clients.floppy = lib.mkIf floppy { name = "Floppy"; redirectUris = [ "https://track.${d}/accounts/oidc/${providerId}/login/callback/" ]; secret = "floppy-oauth-secret"; };
    tidepool.sso.clients.jellyfin = lib.mkIf jf { name = "Jellyfin"; redirectUris = [ "https://media.${d}/sso/OID/redirect/${cfg.jellyfin.provider}" ]; secret = "jellyfin-oauth-secret"; };
    # Jellyfin reads its plugins and their settings when it starts: before the container's start, the plugin and its settings are made ready
    systemd.services.podman-jellyfin = lib.mkIf jf { preStart = "${jellyfinSso}"; restartTriggers = [ jellyfinSso ]; after = [ "nextcloud-oidc-clients.service" ]; };
    sops.secrets = lib.mapAttrs' (_: c: lib.nameValuePair c.secret { }) cfg.clients;
    # the identity provider's discovery document, answered at the address the programs ask (Nextcloud's own rule redirects it, and Immich's OpenID library does not follow a redirect)
    services.nginx.virtualHosts."cloud.${d}".locations."= /.well-known/openid-configuration".extraConfig = "rewrite ^ /index.php/.well-known/openid-configuration last;";
    systemd.services.nextcloud-oidc-clients = {
      description = "Register the single sign-on clients in Nextcloud";
      wantedBy = [ "multi-user.target" ]; after = [ "nextcloud-setup.service" ]; requires = [ "nextcloud-setup.service" ];
      restartTriggers = [ script ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ExecStart = script; };
    };
    # Immich's side of the same declaration (services.nix writes the file; the secret is filled in from sops at activation)
    tidepool.services.immich.settings.oauth = {
      enabled = true;
      issuerUrl = "https://cloud.${d}";   # Immich appends /.well-known/openid-configuration; Nextcloud redirects it to the oidc app, whose issuer is the bare address
      clientId = idOf "immich";
      clientSecret = config.sops.placeholder.${cfg.clients.immich.secret};
      scope = "openid email profile";
      buttonText = config.tidepool.brand.signInLabel;
      autoRegister = true;
      autoLaunch = false;
      tokenEndpointAuthMethod = "client_secret_post";
      signingAlgorithm = "RS256";
    };
    # Floppy's side (floppy.nix holds the rest of its environment): django-allauth's OpenID Connect provider, discovered from the same document; the client secret is filled in from sops at activation
    sops.templates."floppy-sso.env" = lib.mkIf floppy {
      restartUnits = [ "podman-floppy.service" ];
      content = ''
        SOCIAL_PROVIDERS=allauth.socialaccount.providers.openid_connect
        SOCIALACCOUNT_PROVIDERS=${json { openid_connect = {
          OAUTH_PKCE_ENABLED = true;
          APPS = [ { provider_id = providerId; name = config.tidepool.brand.signInLabel; client_id = idOf "floppy"; secret = config.sops.placeholder.${cfg.clients.floppy.secret}; settings.server_url = "https://cloud.${d}/.well-known/openid-configuration"; } ];
        }; }}
      '';
    };
    virtualisation.oci-containers.containers.floppy.environmentFiles = lib.mkIf floppy [ config.sops.templates."floppy-sso.env".path ];
  };
}
