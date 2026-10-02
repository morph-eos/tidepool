# Backup verification (ADR 0015): the checks that say a backup can be restored, without touching production. Nothing here writes to a repository or to a live service.
#   Borg:        borgmatic, checks only (`skip_actions`): the repository, the archives, a dry-run extraction, and the data itself every few months. (The `spot` check, a random sample compared with the live files, does not work on archives that the Borg module made: it reads a manifest only borgmatic's own `create` writes.)
#   PostgreSQL:  a unit that restores the latest backup into a scratch directory, starts a throwaway server on another port with archiving off, checks the databases, and removes it.
{ config, lib, pkgs, ... }:
let
  pg = config.services.postgresql.finalPackage;
  borgCommon = {
    encryption_passcommand = "cat ${config.sops.secrets.borg-passphrase.path}";
    skip_actions = [ "repo-create" "create" "prune" "compact" ];   # the backups themselves are the Borg jobs' business (backup.nix)
    lock_wait = 7200;
  };
  checks = [
    { name = "repository"; frequency = "1 week"; only_run_on = [ "Sunday" ]; }
    { name = "extract"; frequency = "1 week"; only_run_on = [ "Sunday" ]; }
    # every byte of every archive, once a week, on Sunday (the owner's choice, 2026-10-02); `data` implies the `archives` check
    { name = "data"; frequency = "1 week"; only_run_on = [ "Sunday" ]; }
  ];
in
{
  services.borgmatic = {
    enable = true;
    configurations = {
      everything = borgCommon // {
        source_directories = [ "/srv/data" "/var/lib/vaultwarden" ];
        repositories = [ { path = "/mnt/backup16/borg-everything"; label = "everything"; } ];
        inherit checks;
      };
      offsite = borgCommon // {
        source_directories = [ "/srv/data/immich" "/srv/data/nextcloud" "/srv/data/webdav" ];
        repositories = [ { path = "/mnt/big2tb/borg-offsite"; label = "offsite"; } ];
        inherit checks;
      };
    };
  };
  systemd.timers.borgmatic.timerConfig = { OnCalendar = [ "" "*-*-* 04:30:00" ]; Persistent = true; };   # the empty entry resets the package's own "daily"

  systemd.services.pgbackrest-restore-test = {
    description = "Restore the latest pgBackRest backup into a scratch directory and check it";
    path = [ pg pkgs.pgbackrest ];
    unitConfig.RequiresMountsFor = [ "/mnt/backup16" ];
    serviceConfig = {
      Type = "oneshot"; User = "postgres"; Group = "postgres";
      StateDirectory = "restore-test"; PrivateTmp = true; ProtectSystem = "strict"; ProtectHome = true; NoNewPrivileges = true;
      IPAddressDeny = "any";   # the scratch server listens on a socket only; nothing here needs the network
    };
    script = ''
      set -euo pipefail
      dir=$STATE_DIRECTORY/scratch
      cleanup() { pg_ctl -D "$dir" -m fast stop >/dev/null 2>&1 || true; rm -rf "$dir"; }
      rm -rf "$dir"; trap cleanup EXIT
      # `verify` reports a damaged backup in its output and still exits 0 (measured in the lab), so the unit reads the report
      report=$(pgbackrest --stanza=default verify 2>&1); echo "$report"
      if grep -q 'status: error' <<< "$report"; then echo "pgbackrest verify found a damaged backup" >&2; exit 1; fi
      pgbackrest --stanza=default --pg1-path="$dir" --archive-mode=off restore
      # archiving is off twice over: this copy must never push a WAL segment into the real repository
      pg_ctl -D "$dir" -w -t 600 -o "-p 5499 -k $dir -c listen_addresses= -c archive_mode=off -c archive_command=/bin/true" start
      # recovery replays the archived WAL to its end and promotes; only then can the databases be checked
      until [ "$(psql -h "$dir" -p 5499 -d postgres -Atc 'select pg_is_in_recovery()')" = f ]; do sleep 1; done
      for db in immich vaultwarden nextcloud; do
        psql -h "$dir" -p 5499 -d "$db" -qc 'create extension if not exists amcheck'   # in the scratch copy only
        pg_amcheck -h "$dir" -p 5499 -d "$db" >/dev/null
        echo "$db: amcheck passed, $(psql -h "$dir" -p 5499 -d "$db" -Atc "select count(*) from pg_stat_user_tables") tables"
      done
      echo "immich assets in the restored copy: $(psql -h "$dir" -p 5499 -d immich -Atc 'select count(*) from asset')"
    '';
  };
  systemd.timers.pgbackrest-restore-test = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "monthly"; Persistent = true; RandomizedDelaySec = "6h"; };
  };
}
