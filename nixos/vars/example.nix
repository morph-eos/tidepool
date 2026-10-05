# EXAMPLE values for the real host. The real ones live in the private repository (ADR 0003): the domain, the disks by serial, the VPN peers, the admin's key.
{ ... }:
{
  tidepool = {
    domain = "example.invalid";
    secretsFile = ../secrets/example.yaml;   # a stand-in with the right keys (the lab file); the real one is in the private repository
    admin = { name = "admin"; key = builtins.readFile ../keys/admin.pub; };
    boot.mode = "uefi";
    lanInterface = "eno1";                    # the server's own name for its LAN interface (Samba and Avahi listen on it only)
    nas.enable = true;
    nas.timeMachine.path = "/mnt/timemachine";   # the Time Machine partition of the 16 TB disk (mounted by the private values)
    push.enable = true;
    encryption.enable = true;                # LUKS on the disks, unlocked by the TPM (docs/encryption-runbook.md); `encryption.secureBoot = true` follows once the keys exist
    disks = {
      system = "/dev/disk/by-id/EXAMPLE-system-ssd";
      tank = "/dev/disk/by-id/EXAMPLE-tank-ssd";
      backup16 = "/dev/disk/by-id/EXAMPLE-16tb-part1";
      big2tb = "/dev/disk/by-id/EXAMPLE-2tb-part1";
    };
  };
}
