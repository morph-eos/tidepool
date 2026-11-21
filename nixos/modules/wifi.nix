# The server on WiFi: wpa_supplicant through the NixOS module, the passphrase a sops secret, the radio's power saving off (ADR 0019).
# Off by default: tidepool.wifi.enable. On a machine that is cabled instead, set tidepool.lanInterface to the cable's interface name and leave this off.
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
    # a server does not sleep its radio between packets: the card's power saving adds latency and drops (it is on by default on desktop systems).
    # A udev rule at the interface's creation does not hold: the interface is still down then, the driver refuses the setting, and the radio keeps its default.
    # So a service does it once wpa_supplicant has brought the interface up, tries for up to a minute and checks the result.
    systemd.services."wifi-power-save-off" = {
      description = "Switch the WiFi radio's power saving off";
      wantedBy = [ "multi-user.target" ];
      after = [ "wpa_supplicant-${cfg.interface}.service" ];
      wants = [ "wpa_supplicant-${cfg.interface}.service" ];
      path = [ pkgs.iw pkgs.gnugrep ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        for i in $(seq 60); do
          iw dev ${cfg.interface} set power_save off 2>/dev/null
          iw dev ${cfg.interface} get power_save 2>/dev/null | grep -q 'Power save: off' && exit 0
          sleep 1
        done
        echo "power saving is still on for ${cfg.interface}" >&2
        exit 1
      '';
    };
    tidepool.lanInterface = lib.mkDefault cfg.interface;   # Samba and Avahi listen on it
  };
}
