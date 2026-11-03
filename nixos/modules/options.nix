# The few values that differ between the lab and the real machine. Everything else is code shared by both.
{ lib, pkgs, ... }:
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
    desktop = {
      enable = mkEnableOption "the TV session (ADR 0022): GNOME, started by itself for a user that can do almost nothing; the machine is also a media center. Off in the lab (no GPU, no screen)";
      user = mkOption { type = types.str; default = "tv"; description = "The user of the TV session: no sudo, no extra group, no password, no ssh key."; };
      uid = mkOption { type = types.int; default = 1002; description = "The numeric id of that user. It is fixed because the firewall rule that keeps the session off the services' loopback ports names the user by number: the rule is checked when the system is built, where the user does not exist yet. Another user with the same id is an error at build time."; };
      powerProfile = mkOption {
        type = types.nullOr (types.enum [ "power-saver" "balanced" "performance" ]);
        default = null;
        description = "The power profile (power-profiles-daemon, which comes with GNOME) set at every start, so that it does not depend on a click in the session. null leaves the daemon's own choice (it keeps the last one). Measured on the real machine: power-saver takes about 10% longer on a short heavy job and saves about a tenth of a watt at idle.";
      };
    };
    arcMaxMiB = mkOption { type = types.int; default = 3072; description = "Cap of the ZFS cache."; };
    backup.databaseDumps = mkOption { type = types.listOf types.str; default = [ "vaultwarden" ]; description = "PostgreSQL databases that are also dumped (pg_dump, custom format) before each Borg job and kept in both Borg repositories, the offsite one included: pgBackRest's repository is on the same machine as the data, a dump is a copy that leaves with the offsite repository (ADR 0004). Add `nextcloud` or `immich` for those; the cost is the size of the dump in the offsite repository."; };
    mail.smtpLogin = mkOption { type = types.nullOr types.str; default = null; description = "The login Alertmanager presents to the SMTP relay (smtp-relay.brevo.com). Brevo's login is an id of its own (of the form `xxxxxx001@smtp-brevo.com`, on its SMTP page), not an address of your domain; the password is the sops secret `smtp-password`. null keeps `alerts@<domain>`, which only a relay that accepts that login will take."; };
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
      immich.settings = mkOption {
        type = (pkgs.formats.json { }).type; default = { };
        description = "Immich's settings, declared here: with a configuration file, Immich's admin page shows its settings read-only. What is not named keeps Immich's default. Modules add to it (the brand, the single sign-on); a private repository adds its own.";
      };
      immichMachineLearning.enable = mkOption { type = types.bool; default = true; };
    };
  };
}
