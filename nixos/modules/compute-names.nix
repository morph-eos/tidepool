# Names for the Incus instances (ADR 0010, M3 and M4): <instance>.compute.<domain> reaches port 80 of the instance, through nginx, with the certificate on the host.
# Private by default: the name listens on the VPN address only. An instance is also public only if it is listed in tidepool.compute.public (one virtual host each, reviewed like any other line).
# Also gives the VPN a DNS for the `.incus` names, to reach the instances by name (ssh). Needs the DNS of the second wildcard (docs/names.md), so it is off by default: tidepool.compute.names.enable.
{ config, lib, ... }:
let
  cfg = config.tidepool;
  d = cfg.domain;
  opts = cfg.compute;
  zone = "compute.${d}";
  # the bridge's DNS (incusbr0, ADR 0010) answers <instance>.incus for every VM and container; the name is looked up at each request, so an instance created later answers with no change here
  resolver = "resolver 10.100.1.1 valid=10s ipv6=off;";
  tls = if opts.names.tls != null then { sslCertificate = opts.names.tls.cert; sslCertificateKey = opts.names.tls.key; } else { useACMEHost = zone; };
  site = extra: tls // {
    forceSSL = true;
    locations."/" = { proxyPass = "http://$vm.incus:80"; proxyWebsockets = true; };
    extraConfig = resolver + extra;
  };
in
{
  options.tidepool.compute = {
    names.enable = lib.mkEnableOption "the names <instance>.compute.<domain> for the Incus instances (needs the wildcard certificate of the zone: docs/names.md)";
    names.tls = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule { options = { cert = lib.mkOption { type = lib.types.path; }; key = lib.mkOption { type = lib.types.path; }; }; });
      default = null;
      description = "A certificate and key to serve the zone with, instead of the ACME wildcard (the lab: a wildcard cannot be ordered by HTTP-01).";
    };
    public = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[a-z0-9-]+");
      default = [ ];
      description = "Instances whose name is also reachable from the Internet (their port 80, through nginx). Every other instance answers on the VPN only. Each one also needs its own DNS record at the house's address.";
    };
  };
  config = lib.mkIf opts.names.enable {
    services.nginx.virtualHosts = {
      # every instance, VPN only: the captured label is the instance's name (letters, digits and hyphens only, so it cannot name another host)
      "~^(?<vm>[a-z0-9-]+)\\.${lib.replaceStrings [ "." ] [ "\\." ] zone}$" = (site "") // {
        listen = [ { addr = "10.100.0.1"; port = 443; ssl = true; } { addr = "10.100.0.1"; port = 80; ssl = false; } ];
      };
    } // lib.genAttrs (map (n: "${n}.${zone}") opts.public) (name: site "set $vm ${lib.head (lib.splitString "." name)};");
    # the bridge's DNS, offered on the VPN address for the `.incus` names (ssh alpha.incus): dnsmasq answers on the bridge only, so nginx hands the queries over; a client sends there only the
    # names of that domain (docs/names.md)
    services.nginx.streamConfig = ''
      server { listen 10.100.0.1:53 udp; proxy_pass 10.100.1.1:53; proxy_responses 1; proxy_timeout 5s; }
      server { listen 10.100.0.1:53; proxy_pass 10.100.1.1:53; }
    '';
    networking.firewall.interfaces.wg0 = { allowedUDPPorts = [ 53 ]; allowedTCPPorts = [ 53 ]; };
    # the zone's wildcard, in a certificate of its own: if its DNS challenge fails, the other names keep their certificate
    security.acme.certs = lib.mkIf (!cfg.lab && opts.names.tls == null) {
      ${zone} = {
        extraDomainNames = [ "*.${zone}" ];
        group = "nginx";
      };
    };
  };
}
