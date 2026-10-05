# The real machine's hardware (a desktop with an Intel CPU, an Intel WiFi card, a discrete Intel GPU and the platform's firmware TPM; the exact models are in the private repository): what the lab VM never needed.
# Off in the lab (tidepool.lab). The disks and the network are declared elsewhere (storage.nix, wifi.nix).
{ config, lib, ... }:
{
  config = lib.mkIf (!config.tidepool.lab) {
    # the firmware blobs: the WiFi card's and the GPU's: without them neither works
    hardware.enableRedistributableFirmware = true;
    hardware.cpu.intel.updateMicrocode = true;
    boot.kernelModules = [ "kvm-intel" ];   # Incus virtual machines
    # the initrd must find the disks (SATA, NVMe), a USB keyboard for the recovery passphrase, and the TPM that opens the LUKS volumes (the platform's firmware TPM speaks the CRB interface)
    boot.initrd.availableKernelModules = [ "ahci" "nvme" "sd_mod" "xhci_pci" "usbhid" "tpm_crb" "tpm_tis" ];
    networking.useDHCP = lib.mkDefault true;   # the router gives the machine its address (a reservation by the card's address)
  };
}
