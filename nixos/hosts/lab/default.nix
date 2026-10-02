# The lab host: the real host's modules with the lab's values and a few stand-ins (fixtures.nix).
{ config, ... }:
{
  imports = [ ./hardware.nix ./fixtures.nix ];
  networking.hostName = "tidepool-lab";
  tidepool = {
    lab = true;
    domain = "lab.test";
    secretsFile = ../../secrets/lab.yaml;
    admin = { name = "lab"; key = builtins.readFile ../../keys/admin.pub; };
    boot.mode = "bios";
    disks = {
      system = "/dev/vda";
      tank = "/dev/disk/by-id/virtio-TPDATA0001";
      backup16 = "/dev/disk/by-id/virtio-TPXTRA0001";
      big2tb = "/dev/disk/by-id/virtio-TPXTRA0002";
    };
    arcMaxMiB = 768;
    services.immichMachineLearning.enable = false;   # the lab VM has too little memory for it: the real host runs it
    services.jellyfin.enable = false;                # a 2.5 GB image: tried in ADR 0011, not part of the restore drill
  };
}
