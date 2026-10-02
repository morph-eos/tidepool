# Files (ADR 0004, 0007): Borg through its NixOS module, every hour, into two repositories: everything on the 16 TB disk, and the selected family data on the 2 TB disk (the one that goes offsite).
# The databases are not here: pgBackRest covers them (database.nix). The media is a plain copy. The VM disks are replaceable.
{ config, ... }:
let
  common = {
    encryption = { mode = "repokey-blake2"; passCommand = "cat ${config.sops.secrets.borg-passphrase.path}"; };
    compression = "lz4";
    startAt = "hourly";
    prune.keep = { daily = 7; weekly = 4; };
    failOnWarnings = false;   # a file that changes while it is read is a warning, not a failure
  };
in
{
  services.borgbackup.jobs = {
    everything = common // {
      paths = [ "/srv/data" "/var/lib/bitwarden_rs" ];   # Incus is not here: its instances are recovered from the pool itself (docs/restore-drill.md), its settings are declared
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
