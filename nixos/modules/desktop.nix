# The TV session (ADR 0022): the machine is also a media center, so GNOME starts by itself on the screen, for a user that can do almost nothing.
# The services run as their own users and the admin has no local login at all; this user is a third thing: no sudo, no extra group, no password, no ssh key
# (and not in the NAS's group, whose files its tree is not meant to reach). A web browser is the use: the family's pages (photos, cloud, media) are web pages.
# Off by default and in the lab: it needs a screen and a GPU (tidepool.desktop.enable).
{ config, lib, pkgs, ... }:
let
  cfg = config.tidepool;
  user = cfg.desktop.user;
in
{
  config = lib.mkIf cfg.desktop.enable {
    assertions = [
      { assertion = user != cfg.admin.name && user != "root"; message = "tidepool.desktop.user must not be the admin or root: the TV session is the user with no rights."; }
      { assertion = !(config.users.users ? ${cfg.nas.user}) || user != cfg.nas.user; message = "tidepool.desktop.user must not be the NAS share's user."; }
    ];

    users.groups.${user} = { };
    users.users.${user} = {
      isNormalUser = true;
      description = "the TV session";
      group = user;               # its own group: not "users", which the NAS share's user is in
      extraGroups = [ ];          # no wheel, no podman, no incus, no render/video (the session gets the screen and the sound from logind's seat)
      hashedPassword = "!";       # no password: the automatic login does not need one, and nobody can log in with it over ssh (password login is off, and it has no key)
    };

    services.displayManager.gdm = { enable = true; autoSuspend = false; };
    services.desktopManager.gnome.enable = true;
    services.displayManager.autoLogin = { enable = true; inherit user; };
    # no suspend or hibernation of any kind: a server that must answer all the time
    systemd.targets = { sleep.enable = false; suspend.enable = false; hibernate.enable = false; hybrid-sleep.enable = false; };

    # GNOME turns NetworkManager on, which cannot live with the declared network (wpa_supplicant and DHCP in wifi.nix: the build stops on this) and would take over the machine's only
    # connection; the network stays as the configuration declares it, and the TV user may not change it anyway (the polkit rule below)
    networking.networkmanager.enable = lib.mkForce false;

    programs.firefox.enable = true;
    # fewer ways to a shell from the session; this is a convenience, not a lock: a local user can still start one, which is why the rest is what limits it (no rights, polkit below, nix)
    environment.gnome.excludePackages = with pkgs; [ gnome-console gnome-terminal ];

    # a session that cannot be unlocked would be a dead screen: no lock, no idle blank, no screen saver, no user switching, no run dialog
    programs.dconf.profiles.user.databases = [{
      lockAll = true;
      settings = {
        "org/gnome/desktop/screensaver" = { lock-enabled = false; idle-activation-enabled = false; };
        "org/gnome/desktop/session".idle-delay = lib.gvariant.mkUint32 0;
        "org/gnome/desktop/lockdown" = { disable-lock-screen = true; disable-user-switching = true; disable-command-line = true; };
        "org/gnome/settings-daemon/plugins/power" = { sleep-inactive-ac-type = "nothing"; sleep-inactive-battery-type = "nothing"; idle-dim = false; };
      };
    }];

    # what a local session may ask the system for, by default, without a password: the TV session may not switch the machine off, restart it, put it to sleep,
    # manage services, the network or the disks (a family member pressing a menu entry must not take the server down)
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (subject.user == "${user}" &&
            /^org\.freedesktop\.(login1\.|systemd1\.|NetworkManager\.|udisks2\.|packagekit\.|hostname1\.|timedate1\.|locale1\.|machine1\.|home1\.)/.test(action.id)) {
          return polkit.Result.NO;
        }
      });
    '';

    # the Nix daemon is for the admin (a user that can build with Nix can run what it likes inside the sandbox's limits): root and the wheel group only
    nix.settings.allowed-users = [ "root" "@wheel" ];
  };
}
