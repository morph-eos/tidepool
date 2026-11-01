# Where the machine is and who uses it: the time zone, the language, the regional formats and the keyboard layout, declared in one place and set in the private repository, so that
# nobody configures them by hand on the machine or in the session. The defaults are what the host had before (Europe/Rome, English, a US keyboard): a deployment that sets nothing changes nothing.
# The keyboard is set once and applied to the graphical session (the login manager and GNOME) and to the console, including the initrd, where the disk passphrase is typed.
{ config, lib, ... }:
let cfg = config.tidepool.locale; in
{
  options.tidepool.locale = {
    timeZone = lib.mkOption { type = lib.types.str; default = "Europe/Rome"; description = "The time zone, an IANA name (`Europe/Rome`). The clock itself is synchronized (systemd-timesyncd)."; };
    language = lib.mkOption { type = lib.types.str; default = "en_US.UTF-8"; description = "The system language: the messages of the programs, the logs. The machine is administered over ssh and its logs are read and searched, so English is the safe choice even where the people are not English-speaking."; };
    formats = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; example = "it_IT.UTF-8"; description = "The regional formats (dates, 24-hour clock, numbers, money, units, paper) as a locale, when they differ from the language. null: the language's own."; };
    keyboard = {
      layout = lib.mkOption { type = lib.types.str; default = "us"; example = "it"; description = "The keyboard layout, as X11 names it (`us`, `it`, `de`, `fr`, `es`, `gb`): used by the graphical session and, converted, by the console and the initrd."; };
      variant = lib.mkOption { type = lib.types.str; default = ""; example = "nodeadkeys"; description = "The layout's variant, if any."; };
    };
  };

  config = {
    time.timeZone = cfg.timeZone;
    i18n.defaultLocale = cfg.language;
    i18n.extraLocaleSettings = lib.mkIf (cfg.formats != null) (lib.genAttrs [ "LC_TIME" "LC_NUMERIC" "LC_MONETARY" "LC_PAPER" "LC_MEASUREMENT" ] (_: cfg.formats));
    services.xserver.xkb = { inherit (cfg.keyboard) layout variant; };
    # the console's map made from the same layout, and loaded in the initrd: the passphrase that the TPM does not replace (a firmware update, a new board) is typed there, on this keyboard
    console = { useXkbConfig = true; earlySetup = true; };
  };
}
