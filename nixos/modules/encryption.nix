# Encrypted disks unlocked by the TPM, and signed boot images (ADR 0005, decided 2026-10-05: the TPM alone, no PIN, so that the machine reboots by itself; the residual risk is accepted).
# The layout (LUKS under the system root and under the ZFS pool) is in storage.nix. Off by default: tidepool.encryption.enable.
#   1. install with the passphrase in tidepool.encryption.passphraseFile: it becomes the RECOVERY passphrase (keep it in Proton Pass and on paper);
#   2. sbctl create-keys, turn on tidepool.encryption.secureBoot, rebuild, reboot into the firmware's setup mode (the keys are enrolled by itself on the next boot);
#   3. systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 <each LUKS device> (the one imperative step: it needs the recovery passphrase); from then on the disks open by themselves.
{ config, lib, pkgs, ... }:
let cfg = config.tidepool.encryption; in
{
  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      boot.initrd.systemd.enable = true;            # the TPM unlock is systemd's (systemd-cryptsetup in the initrd)
      boot.initrd.systemd.emergencyAccess = false;   # no root shell when the initrd fails: it would be a way in with the disk already open
      security.tpm2.enable = true;
      environment.systemPackages = [ pkgs.tpm2-tools pkgs.sbctl ];   # sbctl is needed BEFORE secureBoot is switched on: it creates the keys that the first lanzaboote switch signs with
      # a thief with the running machine: no DMA from a plugged-in device (the IOMMU on and strict), no Thunderbolt or FireWire
      boot.kernelParams = [ "intel_iommu=on" "iommu.strict=1" ];
      boot.blacklistedKernelModules = [ "thunderbolt" "firewire-core" "firewire-ohci" "firewire-sbp2" ];
      # the 2 TB disk is a plain partition holding a LUKS volume, formatted by hand once (docs/restore-drill.md); nofail: its failure to open must not stop the boot
      boot.initrd.luks.devices = lib.mkIf cfg.big2tb {
        big2tb = { device = config.tidepool.disks.big2tb; allowDiscards = true; crypttabExtraOpts = [ "tpm2-device=auto" "nofail" ]; };
      };
    }
    (lib.mkIf cfg.secureBoot {
      boot.loader.systemd-boot.enable = lib.mkForce false;   # lanzaboote replaces it
      boot.lanzaboote = {
        enable = true;
        pkiBundle = "/var/lib/sbctl";                       # on the encrypted root: the signing key is as safe as the disk
        autoEnrollKeys.enable = true;                       # the keys go into the firmware by themselves when it is in setup mode (the Microsoft ones too: option ROMs of some video cards need them)
      };
    })
  ]);
}
