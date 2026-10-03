# Push notifications to the phone next to the mail (ADR 0012, ADR 0017): ntfy as the server, alertmanager-ntfy as the bridge. Off by default: tidepool.push.enable.
# Critical alerts go by mail AND push; the others by mail only. ntfy is on the PUBLIC side like the other web names, because the phone runs another VPN (Android and iOS
# run one VPN at a time): no login, no topic. Two users with the least they need: `phone` may only read the topic, `bridge` may only write it.
{ config, lib, pkgs, ... }:
let
  cfg = config.tidepool; d = cfg.domain;
  acme = if cfg.lab then { enableACME = true; } else { useACMEHost = d; };
in
{
  options.tidepool.push = {
    enable = lib.mkEnableOption "push notifications through ntfy";
    iphoneRelay = lib.mkEnableOption "the relay through ntfy.sh that wakes an iPhone (it sends ntfy.sh an empty request named by a hash of the topic, measured in the lab; Android needs none)";
  };
  config = lib.mkIf cfg.push.enable {
    sops.secrets.ntfy-env = { };          # NTFY_AUTH_USERS=phone:<bcrypt>:user,bridge:<bcrypt>:user  and  NTFY_AUTH_ACCESS=phone:alerts:read-only,bridge:alerts:write-only
    sops.secrets.ntfy-bridge-env = { };   # the bridge's own login to ntfy
    services.ntfy-sh = {
      enable = true;
      environmentFile = config.sops.secrets.ntfy-env.path;
      settings = {
        listen-http = "127.0.0.1:2586";
        base-url = "https://ntfy.${d}";
        behind-proxy = true;
        auth-file = "/var/lib/ntfy-sh/user.db";
        auth-default-access = "deny-all";   # a topic nobody was granted is closed: guessing its name gets nothing
      } // lib.optionalAttrs cfg.push.iphoneRelay { upstream-base-url = "https://ntfy.sh"; };
    };
    services.prometheus.alertmanager-ntfy = {
      enable = true;
      extraConfigFiles = [ config.sops.secrets.ntfy-bridge-env.path ];   # ntfy.auth.basic.{username,password}
      settings = { http.addr = "127.0.0.1:8111"; ntfy = { baseurl = "http://127.0.0.1:2586"; notification.topic = "alerts"; }; };
    };
    services.nginx.appendHttpConfig = "limit_req_zone $binary_remote_addr zone=ntfy:10m rate=10r/s;";
    services.nginx.virtualHosts."ntfy.${d}" = acme // {
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:2586"; proxyWebsockets = true;
        extraConfig = "limit_req zone=ntfy burst=30 nodelay;";   # guessing the login is slowed at the door (ntfy also locks an address after repeated failures)
      };
    };
    # the routing (critical alerts to mail and push) is in observability.nix, switched by tidepool.push.enable
  };
}
