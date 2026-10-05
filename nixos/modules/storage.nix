# The disks (ADR 0005), declared with disko so that a blank machine gets its layout from the flake: the system disk, and the SSD's ZFS pool with its datasets.
# The two large disks (the 16 TB and the 2 TB) hold only backups and replaceable data: they are mounted here and NEVER formatted by the installer, so a reinstall cannot wipe a backup.
# (They are formatted once, by hand, when first put into service: docs/restore-drill.md.)
{ config, lib, pkgs, ... }:
let
  cfg = config.tidepool;
  enc = cfg.encryption;
  # a LUKS volume around some content: the TPM opens it once enrolled (modules/encryption.nix); until then the passphrase does
  luks = name: content: { type = "luks"; inherit name content; passwordFile = enc.passphraseFile; settings = { allowDiscards = true; crypttabExtraOpts = [ "tpm2-device=auto" ]; }; };
in
{
  disko.devices = {
    disk.system = {
      device = cfg.disks.system;
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          boot = if cfg.boot.mode == "bios"
            then { size = "1M"; type = "EF02"; }
            else { size = "1G"; type = "EF00"; content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; }; };
          root = { size = "100%"; content = let fs = { type = "filesystem"; format = "ext4"; mountpoint = "/"; }; in if enc.enable then luks "cryptroot" fs else fs; };
        };
      };
    };
    disk.tank = {
      device = cfg.disks.tank;
      type = "disk";
      content = { type = "gpt"; partitions.zfs = { size = "100%"; content = let z = { type = "zfs"; pool = "tank"; }; in if enc.enable then luks "crypttank" z else z; }; };
    };
    zpool.tank = {
      type = "zpool";
      options.ashift = "12";
      rootFsOptions = { compression = "lz4"; acltype = "posixacl"; xattr = "sa"; atime = "off"; mountpoint = "none"; };
      datasets = {
        postgres = { type = "zfs_fs"; mountpoint = "/var/lib/postgresql"; options = { mountpoint = "legacy"; recordsize = "16K"; }; };
        data = { type = "zfs_fs"; mountpoint = "/srv/data"; options.mountpoint = "legacy"; };   # legacy: systemd mounts them from fstab; ZFS must not try as well (a failed zfs-mount.service is an alert)
        incus = { type = "zfs_fs"; options.mountpoint = "none"; };   # the ZFS pool of Incus for the instances that need speed (vms.nix)
      };
    };
  };
  # BIOS machines (the lab) boot with grub on the disk; the real machine uses UEFI (ADR 0005: lanzaboote, LUKS and the TPM come with the real layout, not tried in the lab)
  boot.loader.grub = lib.mkIf (cfg.boot.mode == "bios") { enable = true; };
  boot.loader.systemd-boot = lib.mkIf (cfg.boot.mode == "uefi") { enable = true; editor = false; };   # no command-line editor at the boot menu
  boot.loader.efi.canTouchEfiVariables = lib.mkIf (cfg.boot.mode == "uefi") true;

  fileSystems."/mnt/backup16" = { device = cfg.disks.backup16; fsType = "ext4"; options = [ "defaults" "nofail" ]; };
  fileSystems."/mnt/big2tb" = { device = if enc.enable && enc.big2tb then "/dev/mapper/big2tb" else cfg.disks.big2tb; fsType = "ext4"; options = [ "defaults" "nofail" ]; };

  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;
  networking.hostId = "8425e349";
  boot.extraModprobeConfig = "options zfs zfs_arc_max=${toString (cfg.arcMaxMiB * 1024 * 1024)}";
  services.zfs = { autoScrub.enable = true; trim.enable = true; };
}
