# The values that are private (ADR 0003): the domain, the disks by serial, the VPN peers, the admin's key, where to deploy from. Replace every example below.
{ ... }:
{
  networking.hostName = "tidepool";
  tidepool = {
    domain = "example.invalid";
    secretsFile = ./secrets.yaml;        # sops, encrypted to the machine's age key; holds `deploy-key` (the read-only deploy key of THIS repository) among the others
    admin = { name = "admin"; key = "ssh-ed25519 AAAA... admin"; };
    boot.mode = "uefi";
    disks = {
      system = "/dev/disk/by-id/REPLACE-system-ssd";
      tank = "/dev/disk/by-id/REPLACE-tank-ssd";
      backup16 = "/dev/disk/by-id/REPLACE-16tb-part1";
      big2tb = "/dev/disk/by-id/REPLACE-2tb-part1";
    };
    lanInterface = "eno1";
    nas.enable = true;
    push.enable = true;
    deploy = {
      enable = true;
      flake = "git+ssh://git@github.com/OWNER/PRIVATE-REPO.git#tidepool";   # this repository
      privateRepo = { };                                                      # use the deploy key, GitHub's host key pinned
      # inputs = { };  # empty: the server deploys EXACTLY the revision of the public repository that flake.lock pins (two merges). To follow the public main directly (one merge):
      # inputs.tidepool = "git+https://github.com/OWNER/tidepool?ref=main&dir=nixos";
      reboot = { allow = false; };      # a new kernel waits for you; RebootPending warns after a day
    };
  };
}
