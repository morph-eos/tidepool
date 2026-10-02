# Virtual machines and containers for tests (ADR 0010, 0013): Incus with two pools (ZFS on the SSD for what needs speed, a directory pool on the big ext4 disk by default),
# its API and UI on the VPN address only, the VPN reaching the instances' subnet. Containers for services are Podman's (base.nix).
{ config, lib, pkgs, ... }:
let cfg = config.tidepool; in
{
  virtualisation.incus = {
    enable = true;
    ui.enable = true;
    preseed = {
      config."core.https_address" = "10.100.0.1:8443";
      networks = [ { name = "incusbr0"; type = "bridge"; config = { "ipv4.address" = "10.100.1.1/24"; "ipv4.nat" = "true"; "ipv6.address" = "none"; "dns.mode" = "managed"; "dns.domain" = "incus"; }; } ];
      storage_pools = [
        { name = "smr"; driver = "dir"; config.source = "/mnt/big2tb/incus"; }
        { name = "zp"; driver = "zfs"; config.source = "tank/incus"; }
      ];
      profiles = [
        { name = "fast"; devices.root = { path = "/"; pool = "zp"; type = "disk"; }; }   # incus launch ... -p default -p fast
        {
          name = "default";
          config."cloud-init.user-data" = ''
            #cloud-config
            users:
              - name: ${cfg.admin.name}
                sudo: ALL=(ALL) NOPASSWD:ALL
                shell: /bin/bash
                ssh_authorized_keys:
                  - ${cfg.admin.key}
          '';
          devices = { eth0 = { name = "eth0"; network = "incusbr0"; type = "nic"; }; root = { path = "/"; pool = "smr"; type = "disk"; }; };
        }
      ];
    };
  };
  # Incus's own state (its database: instances, pools, volumes) lives on the 2 TB disk, next to the pools that hold the VM disks. A rebuilt system disk then finds
  # its instances as it left them; the alternative, `incus admin recover`, needs the declared network to exist first and is interactive (found by the restore drill).
  fileSystems."/var/lib/incus" = { device = "/mnt/big2tb/incus-state"; fsType = "none"; options = [ "bind" ]; depends = [ "/mnt/big2tb" ]; };
  systemd.services.incus.unitConfig.RequiresMountsFor = "/var/lib/incus";
  systemd.tmpfiles.rules = [ "d /mnt/big2tb/incus 0711 root root -" ];
  systemd.services.incus-preseed = { unitConfig.RequiresMountsFor = "/mnt/big2tb"; after = [ "systemd-tmpfiles-setup.service" ]; };

  networking.firewall.interfaces.incusbr0 = { allowedUDPPorts = [ 53 67 ]; allowedTCPPorts = [ 53 ]; };   # the instances ask the host for an address and for names
  networking.firewall.interfaces.wg0.allowedTCPPorts = [ 8443 ];   # the Incus API and UI: the VPN only
  networking.firewall.extraForwardRules = ''
    iifname "incusbr0" accept
    oifname "incusbr0" ct state established,related accept
    iifname "wg0" oifname "incusbr0" accept
  '';
}
