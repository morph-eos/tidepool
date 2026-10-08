# The admin page (ADR 0021): one page, on the VPN only, that lists the machine's private tools and shows whether each answers, so that Prometheus, Alertmanager, Syncthing, Incus and the services are
# one click from each other. Homepage (gethomepage.dev) through its NixOS module: the page is declared here, there is no script. On by default (tidepool.admin.enable): it is reached once the name `admin.<domain>`
# is in the DNS, pointing at the VPN address (docs/names.md).
{ config, lib, ... }:
let
  cfg = config.tidepool;
  d = cfg.domain;
  b = cfg.brand;
  acme = if cfg.lab then { enableACME = true; } else { useACMEHost = d; };
  # a service of the page: where it is, what it is, how the page asks whether it answers (from the machine itself: a loopback address where the program has one)
  svc = name: href: description: extra: { ${name} = { inherit href description; } // extra; };
  port = 8082;
in
{
  options.tidepool.admin.enable = lib.mkOption { type = lib.types.bool; default = true; description = "The admin page, admin.<domain>, on the VPN only (Homepage). On by default; it is reached once the DNS has the name (an A record to the VPN address); `false` leaves it out."; };
  config = lib.mkIf cfg.admin.enable {
    services.homepage-dashboard = {
      enable = true;
      listenPort = port;
      allowedHosts = "admin.${d}";
      settings = {
        title = "${b.name} admin";
        theme = "dark"; color = "teal"; headerStyle = "boxed"; statusStyle = "dot"; hideVersion = true; target = "_self";
        layout = { Monitoring = { style = "row"; columns = 2; }; Machine = { style = "row"; columns = 3; }; Services = { style = "row"; columns = 4; }; };
      };
      customCSS = ''
        :root { --color-900: ${b.colors.deep}; --color-800: ${b.colors.deep}; }
        html, body, #page_wrapper, .dark\:bg-theme-900 { background-color: ${b.colors.deep} !important; }
      '';
      widgets = [
        { resources = { cpu = true; memory = true; disk = [ "/" "/srv/data" ]; }; }
        { datetime = { text_size = "xl"; format = { dateStyle = "short"; timeStyle = "short"; hour12 = false; }; }; }
      ];
      services = [
        { Monitoring = [
          (svc "Prometheus" "https://metrics.${d}" "metrics, queries, rules" { siteMonitor = "http://127.0.0.1:9090/-/healthy"; widget = { type = "prometheus"; url = "http://127.0.0.1:9090"; }; })
          (svc "Alertmanager" "https://alerts.${d}" "alerts, silences, routes" { siteMonitor = "http://127.0.0.1:9093/-/healthy"; })
        ]; }
        { Machine = [
          (svc "Syncthing" "https://sync.${d}" "file synchronisation" { siteMonitor = "http://127.0.0.1:8384/rest/noauth/health"; })
          (svc "Incus" "https://compute.${d}:8443" "machines and containers (needs its client certificate)" { })
          (svc "Push" "https://push.${d}" "notifications (public)" { siteMonitor = "http://127.0.0.1:2586/v1/health"; })
        ]; }
        { Services = [
          (svc "Nextcloud" "https://cloud.${d}" "files, calendar, contacts, sign-on" { siteMonitor = "https://cloud.${d}/status.php"; })
          (svc "Immich" "https://photos.${d}" "photos and videos" { siteMonitor = "http://127.0.0.1:2283/api/server/ping"; })
          (svc "Jellyfin" "https://media.${d}" "films, series, music" { siteMonitor = "http://127.0.0.1:8096/health"; })
          (svc "Vaultwarden" "https://vault.${d}" "passwords" { siteMonitor = "http://127.0.0.1:8222/alive"; })
        ]; }
      ];
    };
    # Next.js listens on every address unless told: the page is for the VPN, behind nginx
    systemd.services.homepage-dashboard.environment.HOSTNAME = "127.0.0.1";
    services.nginx.virtualHosts."admin.${d}" = acme // {
      forceSSL = true;
      listen = [ { addr = "10.100.0.1"; port = 443; ssl = true; } { addr = "10.100.0.1"; port = 80; ssl = false; } ];
      locations."/" = { proxyPass = "http://127.0.0.1:${toString port}"; proxyWebsockets = true; };
    };
  };
}
