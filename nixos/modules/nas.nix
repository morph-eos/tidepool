# The local NAS (ADR 0005: a share on the 2 TB disk): Samba and Avahi, LAN only, macOS-friendly. Off by default: tidepool.nas.enable.
# What v0 did with setup_samba.sh and UFW rules is the module's settings and one firewall line per port, on the LAN interface only.
{ config, lib, pkgs, ... }:
let cfg = config.tidepool.nas; lan = config.tidepool.lanInterface; in
{
  options.tidepool = {
    lanInterface = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "The LAN interface (a private value: the server's own name for it)."; };
    nas.enable = lib.mkEnableOption "the local NAS share (Samba and Avahi)";
    nas.path = lib.mkOption { type = lib.types.str; default = "/mnt/big2tb/nas"; };
    nas.user = lib.mkOption { type = lib.types.str; default = "nas"; };
    nas.timeMachine.path = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "A Time Machine share (the partition on the 16 TB disk, ADR 0005); null = none. Replaceable data, so not in Borg."; };
  };
  config = lib.mkIf cfg.enable {
    assertions = [ { assertion = lan != null; message = "tidepool.nas.enable needs tidepool.lanInterface"; } ];
    users.users.${cfg.user} = { isNormalUser = true; description = "owner of the NAS share"; group = "users"; };
    systemd.tmpfiles.rules = [ "d ${cfg.path} 0775 ${cfg.user} users -" ] ++ lib.optional (cfg.timeMachine.path != null) "d ${cfg.timeMachine.path} 0775 ${cfg.user} users -";
    services.samba = {
      enable = true;
      openFirewall = false;   # opened below on the LAN interface only
      settings = {
        global = {
          workgroup = "WORKGROUP"; "server string" = "tidepool NAS"; "netbios name" = "tidepool";
          security = "user"; "map to guest" = "never"; "restrict anonymous" = 2;
          "server min protocol" = "SMB2";
          "vfs objects" = "catia fruit streams_xattr"; "fruit:aapl" = "yes"; "fruit:nfs_aces" = "no"; "fruit:model" = "MacSamba";
          "interfaces" = "lo ${lan}"; "bind interfaces only" = "yes";
        };
        NAS = {
          path = cfg.path; browseable = "yes"; "read only" = "no"; "guest ok" = "no";
          "valid users" = cfg.user;
          "create mask" = "0664"; "directory mask" = "0775";
        };
      } // lib.optionalAttrs (cfg.timeMachine.path != null) {
        TimeMachine = {
          path = cfg.timeMachine.path; "valid users" = cfg.user; browseable = "yes"; "read only" = "no"; "guest ok" = "no";
          "fruit:time machine" = "yes";   # the Mac sees it as a backup destination (it encrypts its own backup)
        };
      };
    };
    services.avahi = {
      enable = true; nssmdns4 = true; allowInterfaces = [ lan ]; publish = { enable = true; userServices = true; };
      openFirewall = false;   # the module's default opens UDP 5353 on EVERY interface (seen in the lab's rule list); here only the LAN interface, below
      # what makes the share appear in a Mac's Finder (Samba does not announce itself)
      extraServiceFiles.smb = ''<?xml version="1.0" standalone='no'?><!DOCTYPE service-group SYSTEM "avahi-service.dtd"><service-group><name replace-wildcards="yes">%h</name><service><type>_smb._tcp</type><port>445</port></service></service-group>'';
      extraServiceFiles.adisk = lib.mkIf (cfg.timeMachine.path != null) ''<?xml version="1.0" standalone='no'?><!DOCTYPE service-group SYSTEM "avahi-service.dtd"><service-group><name replace-wildcards="yes">%h</name><service><type>_adisk._tcp</type><txt-record>sys=waMa=0,adVF=0x100</txt-record><txt-record>dk0=adVN=TimeMachine,adVF=0x82</txt-record></service></service-group>'';   # makes it offered as a Time Machine destination
    };
    networking.firewall.interfaces.${lan} = { allowedTCPPorts = [ 445 ]; allowedUDPPorts = [ 5353 ]; };
    environment.systemPackages = [ pkgs.samba ];
  };
}
