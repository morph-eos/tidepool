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
    encryption.enable = true;          # LUKS on the disks, the TPM opens them: docs/encryption-runbook.md of the public repository
    # encryption.secureBoot = true;    # stage 2 of that runbook, after `sbctl create-keys`
    deploy = {
      enable = true;
      flake = "git+ssh://git@github.com/OWNER/PRIVATE-REPO.git#tidepool";   # this repository
      privateRepo = { };                                                      # use the deploy key, GitHub's host key pinned
      # inputs = { };  # empty: the server deploys EXACTLY the revision of the public repository that flake.lock pins (two merges). To follow the public main directly (one merge):
      # inputs.tidepool = "git+https://github.com/OWNER/tidepool?ref=main&dir=nixos";
      # a new kernel is followed by a reboot by itself, in the hour after the Sunday checks (ADR 0018 section 9). The TPM must be sealed to PCR 7 ONLY (the signing key), no PIN, nothing about the kernel
      # (ADR 0005, update 2026-10-03), and the FIRST kernel update must be rehearsed at the console before this is left to run alone. If the machine does not come back, the heartbeat mail says so.
      reboot = { allow = true; window = { lower = "06:00"; upper = "07:00"; }; };
    };
    renovate = { enable = true; repositories = [ "OWNER/tidepool" ]; };   # Renovate on this server, for the PUBLIC repository, with a machine user's token (sops secret `renovate-token`)
  };
}
