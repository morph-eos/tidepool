# The edge (ADR 0008): nginx through the NixOS module, certificates through the NixOS ACME module. One domain; public names and a VPN-only name (Syncthing's GUI).
# Real host: the DNS challenge by CNAME delegation to acme-dns, one wildcard certificate for the domain. Lab: the test CA (Pebble), HTTP-01, one certificate per name.
{ config, lib, pkgs, ... }:
let
  cfg = config.tidepool;
  d = cfg.domain;
  acme = if cfg.lab then { enableACME = true; } else { useACMEHost = d; };
  proxy = port: { proxyPass = "http://127.0.0.1:${toString port}"; proxyWebsockets = true; };
  public = port: acme // { forceSSL = true; locations."/" = proxy port; };
in
{
  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedProxySettings = true;
    recommendedGzipSettings = true;
    sslProtocols = "TLSv1.2 TLSv1.3";
    clientMaxBodySize = "50G";
    proxyTimeout = "86400s";
    appendHttpConfig = ''
      add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
      add_header X-Content-Type-Options nosniff always;
      add_header X-Frame-Options SAMEORIGIN always;
      proxy_request_buffering off;
    '';
    virtualHosts = {
      "vault.${d}" = public 8222;
      "photos.${d}" = public 2283;
      "jelly.${d}" = public 8096;
      # Nextcloud's own module defines its virtual host (php-fpm, headers, limits); only the certificate and TLS are added
      "cloud.${d}" = acme // { forceSSL = true; };
      "dav.${d}" = acme // {
        forceSSL = true;
        basicAuthFile = config.sops.secrets.webdav-htpasswd.path;
        locations."/" = {
          root = "/srv/data/webdav";
          extraConfig = ''
            dav_methods PUT DELETE MKCOL COPY MOVE;
            dav_ext_methods PROPFIND OPTIONS;
            create_full_put_path on;
            dav_access user:rw group:rw;
            client_body_temp_path /srv/data/webdav/.tmp;
          '';
        };
      };
      # reachable only through the VPN: it listens on the WireGuard address
      "sync.${d}" = acme // {
        forceSSL = true;
        listen = [ { addr = "10.100.0.1"; port = 443; ssl = true; } { addr = "10.100.0.1"; port = 80; ssl = false; } ];
        locations."/" = proxy 8384;
      };
    };
  };
  networking.firewall.allowedTCPPorts = [ 80 443 ];

  security.acme = {
    acceptTerms = true;
    defaults.email = lib.mkDefault "admin@${d}";
    certs = lib.mkIf (!cfg.lab) {
      ${d} = {
        extraDomainNames = [ "*.${d}" ];
        dnsProvider = "acme-dns";
        environmentFile = "/var/lib/acme-dns/env";   # ACME_DNS_API_BASE and ACME_DNS_STORAGE_PATH; the credentials file is a sops secret owned by acme (private repository)
        group = "nginx";
      };
    };
  };
}
