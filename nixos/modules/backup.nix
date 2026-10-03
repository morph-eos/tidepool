# Files (ADR 0004, 0007): Borg through its NixOS module, every hour, into two repositories: everything on the 16 TB disk, and the selected family data on the 2 TB disk (the one that goes offsite).
# The databases are not here: pgBackRest covers them (database.nix). The media is a plain copy. The VM disks are replaceable.
{ config, lib, ... }:
let
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
      # Incus is not here: its instances are recovered from the pool itself (docs/restore-drill.md), its settings are declared; the NAS share (2 TB disk) and the Samba users' database are
      paths = [ "/srv/data" "/var/lib/vaultwarden" ] ++ lib.optionals config.tidepool.nas.enable [ config.tidepool.nas.path "/var/lib/samba" ];
      exclude = [ "/srv/data/jellyfin/cache" "/srv/data/immich/model-cache" ];
      repo = "/mnt/backup16/borg-everything";
    };
    offsite = common // {
      paths = [ "/srv/data/immich" "/srv/data/nextcloud" "/srv/data/webdav" ];
      exclude = [ "/srv/data/immich/model-cache" ];
      repo = "/mnt/big2tb/borg-offsite";
    };
  };
  systemd.services.borgbackup-job-everything.unitConfig.RequiresMountsFor = [ "/mnt/backup16" ];
  systemd.services.borgbackup-job-offsite.unitConfig.RequiresMountsFor = [ "/mnt/big2tb" ];
}
