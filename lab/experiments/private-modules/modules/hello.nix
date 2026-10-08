# A made-up service that stands for "anything the public repository does not have": a unit with a secret, an nginx virtual host, and a path in the backup.
{ config, lib, pkgs, ... }:
let cfg = config.extra.hello; d = config.tidepool.domain; in
{
  options.extra.hello.enable = lib.mkEnableOption "the example service";
  config = lib.mkIf cfg.enable {
    sops.secrets.hello-env.sopsFile = ../secrets.yaml;   # this repository's own secrets file, not the public host's
    systemd.services.hello = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python -m http.server 8099 --bind 127.0.0.1 --directory /var/lib/hello";
        EnvironmentFile = config.sops.secrets.hello-env.path;
        DynamicUser = true; StateDirectory = "hello";
      };
    };
    services.nginx.virtualHosts."hello.${d}" = { enableACME = true; forceSSL = true; locations."/".proxyPass = "http://127.0.0.1:8099"; };
    services.borgbackup.jobs.everything.paths = [ "/var/lib/private/hello" ];
  };
}
