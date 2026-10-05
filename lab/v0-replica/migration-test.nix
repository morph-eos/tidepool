# TEST ONLY (lab/v0-migration-u25.sh): the lab host as it must be to receive v0's data: Jellyfin with v0's two media paths, Syncthing keeping the device identity, one declared folder.
{ lib, ... }:
{
  tidepool.services.jellyfin = { enable = lib.mkForce true; mediaMounts = { "/media" = "/srv/data/media"; "/media2" = "/srv/data/media2"; }; };
  tidepool.services.syncthing.restoreIdentity = true;
  services.syncthing.settings.folders.labfolder = { id = "labfolder"; label = "Lab"; path = "/srv/data/syncthing/Sync"; };
  systemd.tmpfiles.rules = [ "d /srv/data/media 0755 root root -" "d /srv/data/media2 0755 root root -" ];
}
