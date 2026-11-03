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
    ensureUsers = [ { name = "vaultwarden"; ensureDBOwnership = true; } { name = "immich"; ensureDBOwnership = true; } ];
    # Immich's container connects over the Unix socket as the container's root, mapped to its own role `immich` (not a superuser) and to its own database only: no password anywhere.
    # The container's root is the host's root, so the map is for that one role: root cannot become `postgres` or any other role through it, and a compromised Immich reaches nothing but its database.
    identMap = "immich root immich";
    authentication = lib.mkBefore ''
      local immich immich peer map=immich
    '';
  };

  # What Immich cannot do as a role that is not a superuser, done by the unit tidepool-db-setup below: its extensions (it creates them itself only when it may), the ownership of what an earlier run as `postgres` created (its
  # own migrations must be able to alter their tables, functions and types), and the databases closed to every role but their own (a role connects only to its own database).
  # Idempotent, run at every start of the service before Immich (and so after a deploy that moves PostgreSQL's or the extensions' version).

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
    tidepool-db-setup = {
      description = "Database roles: Immich's extensions and ownership, and a database for its own role only";
      wantedBy = [ "multi-user.target" ];
      after = [ "postgresql-setup.service" ]; requires = [ "postgresql-setup.service" ];
      before = [ "podman-immich-server.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; User = "postgres"; };
      path = [ config.services.postgresql.package ];
      script = ''
        psql -v ON_ERROR_STOP=1 -d immich -f ${pkgs.writeText "immich-db-setup.sql" ''
          create extension if not exists vector;
          create extension if not exists vchord cascade;
          create extension if not exists cube;
          create extension if not exists earthdistance;
          create extension if not exists pg_trgm;
          create extension if not exists unaccent;
          create extension if not exists "uuid-ossp";
          alter extension vector update;
          alter extension vchord update;
          do $$
          declare r record;
          begin
            for r in
              select c.oid::regclass as obj, c.relkind from pg_class c join pg_namespace n on n.oid = c.relnamespace
              where n.nspname = 'public' and pg_get_userbyid(c.relowner) = 'postgres' and c.relkind in ('r', 'p', 'v', 'm', 'S', 'f')
                and not exists (select 1 from pg_depend d where d.classid = 'pg_class'::regclass and d.objid = c.oid and d.deptype = 'e')
                and (c.relkind <> 'S' or not exists (select 1 from pg_depend d where d.classid = 'pg_class'::regclass and d.objid = c.oid and d.deptype in ('a', 'i')))
            loop
              execute format('alter %s %s owner to immich', case r.relkind when 'S' then 'sequence' when 'v' then 'view' when 'm' then 'materialized view' when 'f' then 'foreign table' else 'table' end, r.obj);
            end loop;
            for r in
              select p.oid::regprocedure as obj, p.prokind from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and pg_get_userbyid(p.proowner) = 'postgres'
                and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
            loop
              execute format('alter %s %s owner to immich', case r.prokind when 'p' then 'procedure' else 'function' end, r.obj);
            end loop;
            for r in
              select t.oid::regtype as obj, t.typtype from pg_type t join pg_namespace n on n.oid = t.typnamespace
              where n.nspname = 'public' and t.typtype in ('e', 'd') and pg_get_userbyid(t.typowner) = 'postgres'
                and not exists (select 1 from pg_depend d where d.classid = 'pg_type'::regclass and d.objid = t.oid and d.deptype = 'e')
            loop
              execute format('alter %s %s owner to immich', case r.typtype when 'd' then 'domain' else 'type' end, r.obj);
            end loop;
            for r in select datname from pg_database where datname in ('immich', 'vaultwarden', 'nextcloud') loop
              execute format('revoke connect on database %I from public', r.datname);
            end loop;
          end $$;
        ''}
      '';
    };
  };
  systemd.tmpfiles.rules = [ "d ${repo} 0770 pgbackrest postgres -" ];
}
