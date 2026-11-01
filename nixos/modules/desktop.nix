# The TV session (ADR 0022): the machine is also a media center, so GNOME starts by itself on the screen, for a user that can do almost nothing.
# The services run as their own users and the admin has no local login at all; this user is a third thing: no sudo, no extra group, no password, no ssh key
# (and not in the NAS's group, whose files its tree is not meant to reach). A web browser is the use: the family's pages (photos, cloud, media) are web pages.
# Off by default and in the lab: it needs a screen and a GPU (tidepool.desktop.enable).
{ config, lib, pkgs, ... }:
let
  cfg = config.tidepool;
  user = cfg.desktop.user;
  # what the session offers: the bar at the bottom first, then the other applications; every other entry is hidden for this user
  offered = cfg.desktop.dash ++ cfg.desktop.apps;
in
{
  options.tidepool.desktop = {
    dash = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "firefox.desktop" "org.gnome.Nautilus.desktop" ];
      description = "The applications of the bar at the bottom of the screen (GNOME's dash), in order, as the names of their desktop files. The browser first: the brand's start page and bookmarks are its.";
    };
    language = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "it_IT.UTF-8";
      description = "The language of the TV session's interface (GNOME, the browser), for its user only: the machine's own language (tidepool.locale.language) stays what it is, English by default, because its logs are read and searched. null: the machine's language.";
    };
    apps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "org.gnome.Settings.desktop" "org.gnome.Loupe.desktop" "org.gnome.Showtime.desktop" "org.gnome.Papers.desktop" "org.gnome.Calculator.desktop" ];
      description = "The other applications that the session shows (Show Applications), besides the bar's. Every other desktop entry of the system is hidden for this user only, by an entry of the same name in its own folder: the admin and the system keep theirs. A package added later is hidden until it is named here.";
    };
  };

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
        # where the machine is is declared (modules/locale.nix), not asked of the network: no location service, no automatic time zone
        "org/gnome/system/location".enabled = false;
        "org/gnome/desktop/datetime".automatic-timezone = false;
        # the bar at the bottom (the dash) is the declared list; no welcome tour on the first login
        "org/gnome/shell" = { favorite-apps = cfg.desktop.dash; welcome-dialog-last-shown-version = "99.0"; };
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

    # The services listen on the loopback with no password of their own where nginx and the VPN are the protection (Syncthing's interface, Prometheus, the APIs behind the names).
    # A local session would reach them directly (measured on the real machine: Syncthing's interface opened for this user with no login). The TV user may use the loopback, which is
    # also the machine's own addresses, for the web only (80 and 443: nginx, which applies the names, the certificates and each service's own login) and for the DNS; the rest of the
    # network is not touched. Unix sockets are not covered: they are protected by their own file modes (and polkit above).
    networking.nftables.tables.tv-session = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority filter; policy accept;
          meta skuid ${user} oifname "lo" tcp dport { 53, 80, 443 } accept
          meta skuid ${user} oifname "lo" udp dport 53 accept
          meta skuid ${user} oifname "lo" reject
        }
      '';
    };

    # the profile is declared, not left to the last click (power-profiles-daemon comes with GNOME and remembers the last choice in its state file)
    systemd.services.power-profile-default = lib.mkIf (cfg.desktop.powerProfile != null) {
      description = "Set the declared power profile (${cfg.desktop.powerProfile})";
      wantedBy = [ "multi-user.target" ];
      after = [ "power-profiles-daemon.service" ];
      wants = [ "power-profiles-daemon.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ExecStart = "${pkgs.power-profiles-daemon}/bin/powerprofilesctl set ${cfg.desktop.powerProfile}"; };
    };

    # The grid of "Show Applications" lists every desktop entry of the system (here 35 of them: disk and log tools, the Syncthing page, a manual...), most of them useless or blocked for this
    # user. GNOME has no list of the allowed ones; but an entry of the same name in the user's own folder shadows the system's, and NoDisplay hides it. So, before the session starts, every
    # system entry that is not offered gets such a hiding entry (the ones this module made before are renewed, so a package that is gone leaves nothing behind).
    systemd.services.tv-apps = {
      description = "Hide the applications that the TV session does not offer, for its user only";
      wantedBy = [ "multi-user.target" ];
      before = [ "display-manager.service" ];
      restartTriggers = [ (pkgs.writeText "tv-apps" (lib.concatStringsSep " " offered)) ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        dir=/home/${user}/.local/share/applications
        install -d -m 0755 -o ${user} -g ${user} /home/${user}/.local /home/${user}/.local/share "$dir"
        for old in "$dir"/*.desktop; do
          [ -e "$old" ] && grep -q '^X-Tidepool-Hidden=true' "$old" && rm -f "$old"
        done
        for f in /run/current-system/sw/share/applications/*.desktop; do
          n=$(basename "$f")
          case " ${lib.concatStringsSep " " offered} " in *" $n "*) continue ;; esac
          printf '[Desktop Entry]\nType=Application\nName=%s\nNoDisplay=true\nX-Tidepool-Hidden=true\n' "''${n%.desktop}" > "$dir/$n"
          chown ${user}:${user} "$dir/$n"
        done
      '';
    };

    # The language of the session, for its user only. GNOME takes a user's language from AccountsService (the file Settings writes when someone picks one), and the login manager starts the
    # session in it, the automatic login too; the locale must be generated, and the browser has its language pack. The machine's own language is not touched.
    i18n.extraLocales = lib.mkIf (cfg.desktop.language != null) [ "${cfg.desktop.language}/UTF-8" ];
    programs.firefox.languagePacks = lib.mkIf (cfg.desktop.language != null) [ (lib.head (lib.splitString "_" cfg.desktop.language)) ];
    systemd.services.tv-language = lib.mkIf (cfg.desktop.language != null) {
      description = "Set the language of the TV session's interface (${cfg.desktop.language})";
      wantedBy = [ "multi-user.target" ];
      before = [ "display-manager.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        f=/var/lib/AccountsService/users/${user}
        install -d -m 0775 /var/lib/AccountsService /var/lib/AccountsService/users
        if [ -f "$f" ] && grep -q '^Language=' "$f"; then sed -i 's/^Language=.*/Language=${cfg.desktop.language}/' "$f"
        elif [ -f "$f" ]; then sed -i '/^\[User\]/a Language=${cfg.desktop.language}' "$f"
        else printf '[User]\nLanguage=${cfg.desktop.language}\n' > "$f"; fi
        chmod 600 "$f"
      '';
    };

    # the Nix daemon is for the admin (a user that can build with Nix can run what it likes inside the sandbox's limits): root and the wheel group only
    nix.settings.allowed-users = [ "root" "@wheel" ];
  };
}
