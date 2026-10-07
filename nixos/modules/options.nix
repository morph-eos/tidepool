# The few values that differ between the lab and the real machine. Everything else is code shared by both.
{ lib, ... }:
let
  inherit (lib) mkOption mkEnableOption types;
in
{
  options.tidepool = {
    lab = mkEnableOption "the lab stand-ins (a test CA, a mail sink, no GPU, small caches)";
    domain = mkOption { type = types.str; description = "The one domain; services are <name>.<domain>."; };
    secretsFile = mkOption { type = types.path; description = "The sops file holding this host's secrets."; };
    admin = {
      name = mkOption { type = types.str; default = "admin"; };
      key = mkOption { type = types.str; description = "The admin's public SSH key."; };
    };
    boot.mode = mkOption { type = types.enum [ "bios" "uefi" ]; default = "uefi"; };
    encryption = {
      enable = mkEnableOption "LUKS on the system disk, the SSD and the 2 TB disk, unlocked by the TPM (ADR 0005); the passphrase given at the installation stays as the RECOVERY key";
      secureBoot = mkEnableOption "signed boot images (lanzaboote) instead of plain systemd-boot: the keys must exist first (`sbctl create-keys`)";
      big2tb = mkOption { type = types.bool; default = true; description = "Encrypt the 2 TB disk too (it holds the offsite repository and the NAS share)."; };
      passphraseFile = mkOption { type = types.str; default = "/tmp/disk-passphrase"; description = "Where the installer finds the passphrase while it formats (disko); it is not kept on the machine."; };
    };
    disks = {
      system = mkOption { type = types.str; description = "The system disk, by a stable path."; };
      tank = mkOption { type = types.str; description = "The SSD that holds the ZFS pool of the services' data."; };
      backup16 = mkOption { type = types.str; description = "The large disk: the repository of everything, the pgBackRest repository, the media."; };
      big2tb = mkOption { type = types.str; description = "The second disk: the offsite repository and the VM pool."; };
    };
    arcMaxMiB = mkOption { type = types.int; default = 3072; description = "Cap of the ZFS cache."; };
    acmeDns.apiBase = mkOption { type = types.str; default = "https://auth.acme-dns.io"; description = "The acme-dns server that holds the certificates' challenge records (ADR 0008): the public instance. The registrations' credentials are the sops secret `acme-dns-credentials`."; };
    wireguard.peers = mkOption { type = types.listOf types.attrs; default = [ ]; };
    services = {
      jellyfin.enable = mkOption { type = types.bool; default = true; };
      jellyfin.mediaMounts = mkOption {
        type = types.attrsOf types.str;
        default = { "/media" = "/mnt/backup16/media"; };
        description = "Media folders read by Jellyfin: the path INSIDE the container = the path on the machine. The libraries of an existing Jellyfin database point at container paths, so a move from another setup keeps its paths here (a private value).";
      };
      syncthing.restoreIdentity = mkEnableOption "the device identity of an existing Syncthing (its certificate and key, the sops secrets `syncthing-cert` and `syncthing-key`), so the device keeps its ID on a move";
      immichMachineLearning.enable = mkOption { type = types.bool; default = true; };
    };
  };
}
