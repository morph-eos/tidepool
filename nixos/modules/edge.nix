# The edge (ADR 0008): nginx through the NixOS module, certificates through the NixOS ACME module. One domain; public names and a VPN-only name (Syncthing's GUI).
# Real host: the DNS challenge by CNAME delegation to acme-dns, one wildcard certificate for the domain. Lab: the test CA (Pebble), HTTP-01, one certificate per name.
{ config, lib, pkgs, ... }:
let
  cfg = config.tidepool;
  d = cfg.domain;
  acme = if cfg.lab then { enableACME = true; } else { useACMEHost = d; };
  proxy = port: { proxyPass = "http://127.0.0.1:${toString port}"; proxyWebsockets = true; };
  public = port: acme // { forceSSL = true; locations."/" = proxy port; };
  catchAll = { rejectSSL = true; locations."/".return = "444"; };   # nginx's 444 closes the connection with no answer; over TLS the handshake is refused (no certificate shown)
  # reachable only through the VPN: the name listens on the WireGuard address, whatever answers behind it stays on the loopback
  vpnOnly = port: acme // {
    forceSSL = true;
    listen = [ { addr = "10.100.0.1"; port = 443; ssl = true; } { addr = "10.100.0.1"; port = 80; ssl = false; } ];
    locations."/" = proxy port;
  };
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
      "media.${d}" = public 8096;
      # Nextcloud's own module defines its virtual host (php-fpm, headers, limits); only the certificate and TLS are added
      "cloud.${d}" = acme // { forceSSL = true; };
      "backup.${d}" = acme // {
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
      # a name that is nobody's gets no answer at all, never another service's page (without these nginx answers an unknown name with the first virtual host of the address): one for the
      # public addresses, one for the VPN address
      "_" = catchAll // { default = true; };
      "_vpn" = catchAll // {
        listen = [ { addr = "10.100.0.1"; port = 443; ssl = true; extraParameters = [ "default_server" ]; } { addr = "10.100.0.1"; port = 80; ssl = false; extraParameters = [ "default_server" ]; } ];
      };
      # the names of the machine's own tools, VPN only (ADR 0008). Incus has no name here: it keeps its own TLS and client certificates on <VPN address>:8443, so a proxy would break them;
      # give that address a DNS name (compute.<domain>) and open https://compute.<domain>:8443
      "sync.${d}" = vpnOnly 8384;      # Syncthing's GUI
      "metrics.${d}" = vpnOnly 9090;   # Prometheus
      "alerts.${d}" = vpnOnly 9093;    # Alertmanager
    };
  };
  networking.firewall.allowedTCPPorts = [ 80 443 ];

  security.acme = {
    acceptTerms = true;
    defaults.email = lib.mkDefault "admin@${d}";
    # every certificate of the real host is ordered by the DNS challenge, delegated by CNAME to acme-dns (ADR 0008); the lab has HTTP-01 and its own test CA
    defaults.dnsProvider = lib.mkIf (!cfg.lab) "acme-dns";
    defaults.environmentFile = lib.mkIf (!cfg.lab) (pkgs.writeText "acme-dns-env" ''
      ACME_DNS_API_BASE=${cfg.acmeDns.apiBase}
      ACME_DNS_STORAGE_PATH=${config.sops.secrets.acme-dns-credentials.path}
    '');
    certs = lib.mkIf (!cfg.lab) {
      ${d} = {
        extraDomainNames = [ "*.${d}" ];
        group = "nginx";
      };
    };
  };
  # the registrations' credentials, one entry per certificate name (docs/names.md, the template's README): a JSON file in lego's format, in the sops file. The module's user reads it; nothing is in the Nix store
  sops.secrets.acme-dns-credentials = lib.mkIf (!cfg.lab) { owner = "acme"; mode = "0400"; };
}
