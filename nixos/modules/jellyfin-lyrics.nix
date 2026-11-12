# Time-synced lyrics for the music library (docs/decisions/0023-floppy.md, nixos/jellyfin/lyrics/README.md): once a week, a sidecar `.lrc` from LRCLIB for each track that has none.
# The media mounts are read-only for Jellyfin, so the job runs on the machine, as a user who can write in the music folders. It talks to a third party (a service run by volunteers: one pause between requests, a name in the User-Agent).
# A run that finds nothing new does nothing; a failure (the unit ending failed) reaches the alert like every other service's.
{ config, lib, pkgs, ... }:
let
  ly = config.tidepool.services.jellyfin.lyrics;
in
{
  config = lib.mkIf ly.enable {
    assertions = [ { assertion = ly.directories != [ ]; message = "tidepool.services.jellyfin.lyrics.directories is empty: name the music folders the job fills."; } ];
    systemd.services.jellyfin-lyrics = {
      description = "Fill the music library's time-synced lyrics (.lrc) from LRCLIB";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [ pkgs.ffmpeg ];   # ffprobe: the tags and the length of a track
      serviceConfig = {
        Type = "oneshot"; User = ly.user; StateDirectory = "jellyfin-lyrics"; TimeoutStartSec = "6h";
        Nice = 10; IOSchedulingClass = "idle";
        ProtectSystem = "strict"; ProtectHome = true; PrivateTmp = true; NoNewPrivileges = true;
        ReadWritePaths = ly.directories;
      };
      # a plain `.lrc` that the script replaces with a synced one is copied under the state directory first
      script = lib.concatMapStringsSep "\n" (d: "${pkgs.python3}/bin/python3 ${../jellyfin/lyrics/lrc_fill.py} ${lib.escapeShellArg d} --backup /var/lib/jellyfin-lyrics/replaced") ly.directories;
    };
    systemd.timers.jellyfin-lyrics = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = ly.calendar; Persistent = true; RandomizedDelaySec = "30min"; };
    };
  };
}
