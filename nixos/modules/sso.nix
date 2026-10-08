# Single sign-on (ADR 0011, 0020): Nextcloud's oidc app is the identity provider. The clients (the programs that log in through it) are declared here and registered after Nextcloud's setup,
# and each program's own side is configured from the same declaration. Today: Immich. Off by default (tidepool.sso.enable): it needs Nextcloud and the clients' secrets.
# This is an exception to P1 (docs/exceptions.md, entry 4): the oidc app has no declarative setting for its clients, only the `occ oidc:create` command.
{ config, lib, pkgs, ... }:
let
  cfg = config.tidepool.sso;
  d = config.tidepool.domain;
  occ = "${config.services.nextcloud.occ}/bin/nextcloud-occ";
  json = builtins.toJSON;
  # `occ oidc:create` wants a client id of 32 to 64 printable characters: a stable one made from the domain
  idOf = n: "${n}-" + builtins.substring 0 32 (builtins.hashString "sha256" "${n}-${d}");
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
  script = pkgs.writeShellScript "nextcloud-oidc-clients" ("set -euo pipefail\n" + lib.concatStrings (lib.mapAttrsToList (n: c: register (idOf n) c) cfg.clients));
in
{
  options.tidepool.sso = {
    enable = lib.mkEnableOption "Nextcloud as the single sign-on of the other services";
    clients = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule { options = {
        name = lib.mkOption { type = lib.types.str; description = "The client's name, as the identity provider shows it."; };
        redirectUris = lib.mkOption { type = lib.types.listOf lib.types.str; };
        secret = lib.mkOption { type = lib.types.str; description = "The sops secret that holds the client secret (32 to 64 printable characters, no colon)."; };
      }; });
      default = { };
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [ { assertion = config.services.nextcloud.enable; message = "tidepool.sso.enable needs Nextcloud"; } ];
    tidepool.sso.clients.immich = { name = "Immich"; redirectUris = [ "https://photos.${d}/auth/login" "https://photos.${d}/user-settings" "app.immich:///oauth-callback" ]; secret = "immich-oauth-secret"; };
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
      buttonText = "Login with ${config.tidepool.brand.name}";
      autoRegister = true;
      autoLaunch = false;
      tokenEndpointAuthMethod = "client_secret_post";
      signingAlgorithm = "RS256";
    };
  };
}
