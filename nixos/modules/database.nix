# PostgreSQL 17, native, for every service that can use it (ADR 0006, 0011), with pgBackRest through its NixOS module (ADR 0004).
# The repository is on the large disk. The overrides below are the exception of docs/exceptions.md, entry 1: the module is built for a repository on another host.
{ config, lib, pkgs, ... }:
let cfg = config.tidepool; repo = "/mnt/backup16/pgbackrest"; in
{
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_17;
    extensions = ps: [ ps.pgvector ps.vectorchord ];
    settings = { shared_preload_libraries = "vchord.so"; archive_timeout = 30; };
    ensureDatabases = [ "immich" "vaultwarden" ];   # Nextcloud's module creates and orders its own (database.createLocally)
    ensureUsers = [ { name = "vaultwarden"; ensureDBOwnership = true; } ];
    # Immich's container connects over the Unix socket as the container's root, mapped to the postgres role: no password anywhere
    identMap = "postgres root postgres";
  };

  services.pgbackrest = {
    enable = true;
    repos.localhost = { path = repo; retention-full = 2; cipher-type = "aes-256-cbc"; };
    stanzas.default.jobs = {
      weekly = { schedule = "Sun 03:00"; type = "full"; };
      daily = { schedule = "Mon..Sat 03:00"; type = "diff"; };
    };
    settings.compress-type = "zst";
  };

  # exceptions.md, entry 1
  users.users.pgbackrest.homeMode = "770";
  systemd.services = lib.genAttrs [ "pgbackrest-default-weekly" "pgbackrest-default-daily" ] (_: {
    serviceConfig = { User = lib.mkForce "postgres"; Group = lib.mkForce "postgres"; };
    unitConfig.RequiresMountsFor = [ "/mnt/backup16" ];
  }) // {
    postgresql.serviceConfig.ReadWritePaths = [ "-${repo}" ];   # postgresql.service is sandboxed: archive-push runs inside it and needs the repository writable
  };
  systemd.tmpfiles.rules = [ "d ${repo} 0770 pgbackrest postgres -" ];
}
