# The server on WiFi (the Ethernet cable is not connected yet, 2026-10-05): wpa_supplicant through the NixOS module, the passphrase a sops secret, the radio's power saving off.
# Off by default: tidepool.wifi.enable. With the cable, set tidepool.lanInterface to its name and leave this off.
{ config, lib, pkgs, ... }:
let cfg = config.tidepool.wifi; in
{
  options.tidepool.wifi = {
    enable = lib.mkEnableOption "the WiFi connection (the machine's only network until the cable is connected)";
    interface = lib.mkOption { type = lib.types.str; description = "The wireless interface (the machine's own name for it, a private value)."; };
    ssid = lib.mkOption { type = lib.types.str; description = "The network's name (a private value)."; };
  };
  config = lib.mkIf cfg.enable {
    # one line: psk_home=<the 64 hex digits that `wpa_passphrase 'SSID' 'passphrase'` prints after psk=>: the raw key, derived from the name and the passphrase.
    # wpa_supplicant runs as its own user and must read it (as root-only it failed: "Permission denied"); a changed secret (a new WiFi passphrase) restarts it
    sops.secrets.wifi-psk = { owner = "wpa_supplicant"; restartUnits = [ "wpa_supplicant-${cfg.interface}.service" ]; };
    networking.wireless = {
      enable = true;
      interfaces = [ cfg.interface ];
      secretsFile = config.sops.secrets.wifi-psk.path;
      networks.${cfg.ssid}.pskRaw = "ext:psk_home";   # the key comes from the secret, never from the Nix store (`psk = "ext:..."` is written with quotes and read as a literal passphrase: tried, the handshake fails)
    };
    networking.interfaces.${cfg.interface}.useDHCP = true;
    # a server does not sleep its radio between packets: the card's power saving adds latency and drops (it was on under Ubuntu's NetworkManager)
    services.udev.extraRules = ''ACTION=="add", SUBSYSTEM=="net", KERNEL=="${cfg.interface}", RUN+="${pkgs.iw}/bin/iw dev %k set power_save off"'';
    tidepool.lanInterface = lib.mkDefault cfg.interface;   # Samba and Avahi listen on it
  };
}
