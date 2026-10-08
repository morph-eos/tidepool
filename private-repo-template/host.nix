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
    # The network. Until the Ethernet cable is connected the machine is on WiFi: the LAN interface is then the WiFi one (set by tidepool.wifi). With the cable: remove `wifi`, set lanInterface to the Ethernet interface's name.
    wifi = { enable = true; interface = "REPLACE-wifi-interface"; ssid = "REPLACE-with-your-network-name"; };   # the secret `wifi-psk` in secrets.yaml holds one line: psk_home=<64 hex digits from `wpa_passphrase 'SSID' 'passphrase'`>
    wireguard.peers = import ./vpn-peers.nix;   # one entry per device: tools/add-peer.sh (docs/vpn-clients.md); the server's own public key is in vpn-server.pub (written by tools/secrets-init.sh)
    nas.enable = true;
    nas.timeMachine.path = "/mnt/timemachine";   # the Time Machine partition of the 16 TB disk; Linux cannot write a journaled HFS+, so make it ext4 and mount it below. Remove both if you have no Mac
    # The name, palette and logo are ON by default (nixos/brand/ of the public repository). For your own: copy that directory here and say `brand.file = ./brand/brand.json;`; `brand.enable = false;` turns it off (docs/decisions/0020-brand-identity.md)
    # sso.enable = true;                 # Nextcloud as the single sign-on of Immich; needs the secret `immich-oauth-secret` (tools/secrets-init.sh makes it)
    # The admin page, admin.<domain> on the VPN (the private tools and the services on one page, with a status for each), is ON by default; it needs the DNS record `admin` (docs/names.md, ADR 0021). `admin.enable = false;` leaves it out
    # compute.names.enable = true;        # <instance>.compute.<domain> for the Incus instances' port 80, VPN only: needs the DNS of docs/names.md first
    # compute.public = [ "alpha" ];      # the instances that are also reachable from the Internet (each needs its own DNS record)
    # offsite.proton.enable = true;   # the copy of the 2 TB Borg repository to Proton Drive (ADR 0007): needs the secret `proton-keyring-password` (a long random line) and one `sudo proton-offsite-cli auth login`, runbook 1.6
    push.enable = true;
    encryption.enable = true;          # LUKS on the disks, the TPM opens them: docs/encryption-runbook.md of the public repository
    # encryption.secureBoot = true;    # stage 2 of that runbook, after `sbctl create-keys`
    deploy = {
      enable = false;                   # switched on at runbook 1.9, once the first kernel update has been rehearsed at the console
      interval = "Mon..Sat *:0/10";     # no tick on Sunday: the weekly borgmatic checks (Sunday 04:30, hours on 14.6 TB) must not be cut by the 06:00 reboot (ADR 0018 section 9)
      flake = "git+ssh://git@github.com/OWNER/PRIVATE-REPO.git#tidepool";   # this repository
      privateRepo = { };                                                      # use the deploy key, GitHub's host key pinned
      # inputs = { };  # empty: the server deploys EXACTLY the revision of the public repository that flake.lock pins (two merges). To follow the public main directly (one merge):
      # inputs.tidepool = "git+https://github.com/OWNER/tidepool?ref=main&dir=nixos";
      # a new kernel is followed by a reboot by itself, in the hour after the Sunday checks (ADR 0018 section 9). The TPM must be sealed to PCR 7 ONLY (the signing key), no PIN, nothing about the kernel
      # (ADR 0005, update 2026-10-03), and the FIRST kernel update must be rehearsed at the console before this is left to run alone. If the machine does not come back, the heartbeat mail says so.
      reboot = { allow = true; window = { lower = "06:00"; upper = "07:00"; }; };
    };
    # Jellyfin: the paths INSIDE the container are what existing libraries point at; the right-hand side is where the folder is on the machine
    # services.jellyfin.mediaMounts = { "/media" = "/mnt/backup16/media"; };
    # services.syncthing.restoreIdentity = true;   # the device keeps its ID: secrets `syncthing-cert` and `syncthing-key`
    renovate = { enable = false; repositories = [ "OWNER/tidepool" ]; };   # Renovate on this server, for the PUBLIC repository, with a machine user's token (sops secret `renovate-token`)
  };
  fileSystems."/mnt/timemachine" = { device = "/dev/disk/by-id/REPLACE-16tb-part2"; fsType = "ext4"; options = [ "nofail" ]; };
}
