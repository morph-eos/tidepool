# Files (ADR 0004, 0007): Borg through its NixOS module, every hour, into two repositories: everything on the 16 TB disk, and the selected family data on the 2 TB disk (the one that goes offsite).
# The databases are not here: pgBackRest covers them (database.nix); the ones listed in tidepool.backup.databaseDumps are also dumped into both repositories, because pgBackRest's repository is on the same machine as the data. The media is a plain copy. The VM disks are replaceable.
{ config, lib, ... }:
let
  dumps = config.tidepool.backup.databaseDumps;
  dumpDir = "/var/lib/tidepool-db-dumps";
  common = {
    encryption = { mode = "repokey-blake2"; passCommand = "cat ${config.sops.secrets.borg-passphrase.path}"; };
    compression = "lz4";
    startAt = "hourly";
    # Every hourly archive for 3 days, then one a day until the 14th day, then one a week for 4 weeks (measured on archives with made-up dates: 87 kept, the oldest 40 days old).
    # 14 days is the longest a pgBackRest point-in-time restore can reach (two weekly full backups kept), so a database restored to any moment in that window finds files at least from the same day;
    # inside the first 3 days it finds files from the same hour. (`within` does not count toward `daily`: the daily days come after it.)
    prune.keep = { within = "3d"; daily = 11; weekly = 4; };
    failOnWarnings = false;   # a file that changes while it is read is a warning, not a failure
    # The weekly full check (verify.nix) holds the repository exclusively; the job waits for it instead of failing. A waiting job looks again once a minute (measured).
    # 12 hours: the check of a repository of 1 TB on a slow disk (50 MB/s) takes about 5.6 hours (ADR 0015), so this is twice the worst case computed.
    # A wait that long must not hide a hung check: the rule BackupJobRunningLong (observability.nix) warns when a backup unit has been running for 8 hours.
    extraArgs = [ "--lock-wait" "43200" ];
  };
in
{
  services.borgbackup.jobs = {
    everything = common // {
      # Incus is not here: its instances are recovered from the pool itself (docs/restore-drill.md), its settings are declared; the NAS share (2 TB disk), the Samba users' database and (with signed boot images) the Secure Boot signing keys are
      paths = [ "/srv/data" "/var/lib/vaultwarden" ] ++ lib.optional (dumps != [ ]) dumpDir ++ lib.optionals config.tidepool.nas.enable [ config.tidepool.nas.path "/var/lib/samba" ] ++ lib.optional config.tidepool.encryption.secureBoot "/var/lib/sbctl";
      exclude = [ "/srv/data/jellyfin/cache" "/srv/data/immich/model-cache" ];
      repo = "/mnt/backup16/borg-everything";
    };
    offsite = common // {
      # Vaultwarden's files (the attachments, the signing key, the settings) and the dumps of the databases listed in tidepool.backup.databaseDumps: the databases themselves are in pgBackRest, on the same machine as the data
      paths = [ "/srv/data/immich" "/srv/data/nextcloud" "/srv/data/webdav" "/var/lib/vaultwarden" ] ++ lib.optional (dumps != [ ]) dumpDir;
      exclude = [ "/srv/data/immich/model-cache" "/var/lib/vaultwarden/icon_cache" "/var/lib/vaultwarden/tmp" ];
      repo = "/mnt/big2tb/borg-offsite";
    };
  };
  systemd.services = lib.mkMerge [
    {
      borgbackup-job-everything.unitConfig.RequiresMountsFor = [ "/mnt/backup16" ];
      borgbackup-job-offsite.unitConfig.RequiresMountsFor = [ "/mnt/big2tb" ];
    }
    (lib.mkIf (dumps != [ ]) {
      # a dump before each job (and so before the backups that come ahead of a deploy): `wants`, not `requires`, so that a failed dump is reported (BackupJobFailed) without stopping the files' backup
      tidepool-db-dump = {
        description = "Dump the databases kept in both Borg repositories";
        after = [ "postgresql.service" ]; requires = [ "postgresql.service" ];
        serviceConfig = { Type = "oneshot"; User = "postgres"; StateDirectory = "tidepool-db-dumps"; StateDirectoryMode = "0700"; WorkingDirectory = dumpDir; };
        # written to a new file and moved over the old one: a dump that fails half-way never replaces the last good one
        script = lib.concatMapStrings (db: ''
          ${config.services.postgresql.package}/bin/pg_dump --format=custom --file=${db}.dump.new ${db}
          mv ${db}.dump.new ${db}.dump
        '') dumps;
      };
      borgbackup-job-everything = { wants = [ "tidepool-db-dump.service" ]; after = [ "tidepool-db-dump.service" ]; };
      borgbackup-job-offsite = { wants = [ "tidepool-db-dump.service" ]; after = [ "tidepool-db-dump.service" ]; };
    })
  ];
}
