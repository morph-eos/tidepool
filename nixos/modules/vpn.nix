# The personal VPN (ADR 0009): plain WireGuard through the NixOS module. SSH and every administration port are open on this interface only.
{ config, lib, ... }:
let cfg = config.tidepool; in
{
  networking.wireguard.interfaces.wg0 = {
    ips = [ "10.100.0.1/24" ];
    listenPort = 51820;
    privateKeyFile = config.sops.secrets.wg-private-key.path;
    peers = cfg.wireguard.peers;
  };
  networking.firewall.allowedUDPPorts = [ 51820 ];
  networking.firewall.interfaces.wg0.allowedTCPPorts = [ 2222 ];
  # nginx and Incus bind addresses on wg0, so they start after the interface exists
  systemd.services.nginx = { after = [ "wireguard-wg0.service" ]; requires = [ "wireguard-wg0.service" ]; };
  systemd.services.incus = { after = [ "wireguard-wg0.service" ]; requires = [ "wireguard-wg0.service" ]; };
}
