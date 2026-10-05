# The lab host on UEFI with encrypted disks, the TPM and (when switched on) signed boot images: the layout of the real machine, tried in a VM with an emulated TPM 2.0 and Secure Boot firmware.
{ lib, ... }:
{
  imports = [ ../lab ];
  tidepool.boot.mode = lib.mkForce "uefi";
  tidepool.encryption.enable = true;
  boot.kernelParams = [ "console=ttyS0,115200" ];   # the passphrase prompt of the initrd is then on the serial line (the lab VM has no screen)
}
