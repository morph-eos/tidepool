# The lab VM (QEMU, virtio disks, DHCP from QEMU's user-mode network). The disk layout itself is declared in modules/storage.nix (disko).
{ ... }:
{
  boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" "virtio_net" "ahci" "sd_mod" "xhci_pci" ];
  networking.useDHCP = true;
}
