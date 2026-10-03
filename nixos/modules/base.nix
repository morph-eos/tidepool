# The host layer (docs/specs/host.md): an admin with a key and sudo, SSH, fail2ban, a crash dump, time, the container engine (Podman, ADR 0013) and the firewall on.
{ config, lib, pkgs, ... }:
let cfg = config.tidepool; in
{
  users.users.${cfg.admin.name} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [ cfg.admin.key ];
  };
  security.sudo.wheelNeedsPassword = false;

  # the flake commands: the admin at a shell, Renovate's `nix flake update`, nixos-rebuild's own calls
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  time.timeZone = "Europe/Rome";
  services.timesyncd.enable = true;

  services.openssh = {
    enable = true;
    ports = [ 2222 ];
    openFirewall = cfg.lab;   # on the real host SSH is open on the VPN interface only (vpn.nix, ADR 0009); the lab is reached through QEMU's forwarding
    settings = { PasswordAuthentication = false; KbdInteractiveAuthentication = false; PermitRootLogin = "prohibit-password"; MaxAuthTries = 3; };
  };
  services.fail2ban = {
    enable = true;
    maxretry = 3;
    jails.sshd.settings = { enabled = true; port = "2222"; backend = "systemd"; findtime = 600; bantime = 3600; };
  };

  boot.crashDump = { enable = true; reservedMemory = if cfg.lab then "128M" else "256M"; };
  boot.kernelParams = [ "softlockup_panic=1" "nmi_watchdog=1" "panic=10" ];

  # Podman, not Docker (ADR 0013): no daemon, one nftables table; containers are declared as units (virtualisation.oci-containers), there is no Compose file
  virtualisation.podman = { enable = true; defaultNetwork.settings.dns_enabled = true; };
  virtualisation.oci-containers.backend = "podman";
  networking.firewall.interfaces."podman*" = { allowedUDPPorts = [ 53 ]; allowedTCPPorts = [ 53 ]; };   # the engine's DNS answers on each bridge's address

  networking.nftables.enable = true;
  networking.firewall.filterForward = true;
  networking.firewall.extraForwardRules = ''
    iifname "podman*" accept
    oifname "podman*" ct state established,related accept
  '';
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  # Updates (ADR 0016) leave the previous system installed so that a rollback is possible: 4.7 GiB per generation, and an update that crosses a mass rebuild adds 5 GiB at once.
  # The system disk is 119 GB, so old generations are collected after two weeks, the store is deduplicated, and the boot menu keeps ten entries.
  nix.gc = { automatic = true; dates = "weekly"; options = "--delete-older-than 14d"; };
  nix.optimise.automatic = true;
  boot.loader.grub.configurationLimit = 10;
  boot.loader.systemd-boot.configurationLimit = 10;
  # images that no container uses any more (the old digest after an update) are removed weekly
  virtualisation.podman.autoPrune = { enable = true; dates = "weekly"; };

  environment.systemPackages = with pkgs; [ curl jq htop ];
  system.stateVersion = "26.05";
}
