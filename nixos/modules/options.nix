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
    disks = {
      system = mkOption { type = types.str; description = "The system disk, by a stable path."; };
      tank = mkOption { type = types.str; description = "The SSD that holds the ZFS pool of the services' data."; };
      backup16 = mkOption { type = types.str; description = "The large disk: the repository of everything, the pgBackRest repository, the media."; };
      big2tb = mkOption { type = types.str; description = "The second disk: the offsite repository and the VM pool."; };
    };
    arcMaxMiB = mkOption { type = types.int; default = 3072; description = "Cap of the ZFS cache."; };
    wireguard.peers = mkOption { type = types.listOf types.attrs; default = [ ]; };
    services = {
      jellyfin.enable = mkOption { type = types.bool; default = true; };
      immichMachineLearning.enable = mkOption { type = types.bool; default = true; };
    };
  };
}
