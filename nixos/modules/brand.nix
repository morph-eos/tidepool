# The brand (docs/decisions/0020-brand-identity.md): one name, one palette, one logo (nixos/brand/brand.json and logo.svg), applied where a program has a setting for it:
# Nextcloud's theming, Jellyfin's themes and branding, Immich's configuration, Prometheus' title, the operating system's name, the mail's sender, Samba's name. No program's own files are patched or restyled from outside.
# The data is JSON, so that tools that are not Nix can read it too. Another repository says `tidepool.brand.file = ./brand/brand.json;` (fields it leaves out keep the defaults), or sets single options.
{ config, lib, pkgs, ... }:
let
  cfg = config.tidepool.brand;
  d = config.tidepool.domain;
  c = cfg.colors;
  defaults = lib.importJSON ../brand/brand.json;
  user = lib.importJSON cfg.file;
  data = lib.recursiveUpdate defaults user;
  # a file named in the brand is relative to the JSON that names it
  fileOf = field: if (user.${field} or null) != null then builtins.dirOf cfg.file + "/${user.${field}}" else if (defaults.${field} or null) != null then ../brand + "/${defaults.${field}}" else null;

  hex2 = n: let h = lib.toHexString n; in lib.toLower (if builtins.stringLength h == 1 then "0${h}" else h);
  chan = hex: i: lib.fromHexString (builtins.substring i 2 (lib.removePrefix "#" hex));
  rgb = hex: lib.concatStringsSep " " (map (i: toString (chan hex i)) [ 0 2 4 ]);   # "#0f7a8c" -> "15 122 140", the form some programs' variables use
  mix = base: other: t: "#" + lib.concatMapStrings (i: hex2 (builtins.floor ((chan base i) * (1.0 - t) + (chan other i) * t + 0.5))) [ 0 2 4 ];
  # twelve steps from the one colour, by mixing with white and black: the scale Immich's variables expect
  scale = base: {
    "050" = mix base "#ffffff" 0.92; "100" = mix base "#ffffff" 0.84; "200" = mix base "#ffffff" 0.68; "300" = mix base "#ffffff" 0.5; "400" = mix base "#ffffff" 0.3; "500" = mix base "#ffffff" 0.14;
    "600" = base; "700" = mix base "#000000" 0.2; "800" = mix base "#000000" 0.38; "900" = mix base "#000000" 0.55; "950" = mix base "#000000" 0.7;
  };
  vars = prefix: sc: lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "${prefix}${k}: ${v};") sc);
  noZero = lib.mapAttrs' (k: v: lib.nameValuePair (lib.removePrefix "0" k) v);   # "050" -> "50"

  # a logo inside a stylesheet that lives in a program's own settings (no file to point to)
  inline = file: "url(\"data:image/svg+xml," + lib.escapeURL (lib.replaceStrings [ "\n" ] [ " " ] (builtins.readFile file)) + "\")";
  wide = if cfg.wordmark != null then cfg.wordmark else cfg.logo;

  # Jellyfin Web has a theme system: config.json lists the themes (one is the default), each a folder with a theme.css that sets MUI-style variables. A theme of the brand is added next to the
  # built-in ones and made the default, so every user who has not chosen one (and the login page) gets it, in every client built on Jellyfin Web, the Android app included (a wrapper around it).
  # It imports the dark theme and changes its variables, so it follows that theme's updates. The server's Branding CSS (below) only carries the logo.
  jellyfinThemeCss = ''
    @import url("../dark/theme.css");
    :root { --jf-palette-primary-main: ${c.primaryOnDark}; --jf-palette-primary-dark: ${c.primary}; --jf-palette-primary-contrastText: ${c.deep}; --jf-palette-secondary-main: ${c.accent}; --jf-palette-secondary-contrastText: ${c.text};
            --jf-palette-background-default: ${mix c.deep "#000000" 0.6}; --jf-palette-background-paper: ${c.deep}; --jf-palette-AppBar-defaultBg: ${c.deep}; }
    .pageTitleWithDefaultLogo, .layout-tv .pageTitleWithDefaultLogo { background-image: ${inline wide}; }
  '';
  jellyfinThemeDir = pkgs.runCommand "jellyfin-theme-${cfg.slug}" { } "mkdir $out; cp ${pkgs.writeText "theme.css" jellyfinThemeCss} $out/theme.css";
  # the image's own config.json (nixos/brand/jellyfin-web-config.json, taken from the pinned image) with the brand's theme added as the default: replaced whole, so it is checked against the image at every update
  jellyfinWebConfig = let orig = lib.importJSON ../brand/jellyfin-web-config.json; in pkgs.writeText "jellyfin-web-config.json" (builtins.toJSON (orig // {
    themes = map (t: removeAttrs t [ "default" ]) orig.themes ++ [ { name = cfg.name; id = cfg.slug; color = c.deep; default = true; } ];
  }));
  jellyfinCss = ''
    img[src*="icon-transparent"], img[src*="banner"] { content: ${inline wide}; }
  '';
  immichCss = ''
    :root { --immich-primary: ${rgb c.primary}; --immich-dark-primary: ${rgb c.primaryOnDark}; ${vars "--immich-ui-primary-" (noZero (scale c.primary))} }
    img.h-24.aspect-square { content: ${inline cfg.logo}; }
  '';

  # Jellyfin reads its branding from config/branding.xml: written whole (tmpfiles' f+ replaces the file; the escapes give the line breaks)
  jellyfinBranding = lib.replaceStrings [ "\n" "%" ] [ "\\n" "%%" ] ''<?xml version="1.0" encoding="utf-8"?>
<BrandingOptions><LoginDisclaimer>${lib.escapeXML cfg.name} - ${lib.escapeXML cfg.tagline}</LoginDisclaimer><CustomCss>${lib.escapeXML jellyfinCss}</CustomCss><SplashscreenEnabled>false</SplashscreenEnabled></BrandingOptions>
'';
  nextcloudBrand = pkgs.writeShellScript "nextcloud-brand" ''
    occ=${config.services.nextcloud.occ}/bin/nextcloud-occ
    $occ theming:config name ${lib.escapeShellArg cfg.name}
    $occ theming:config slogan ${lib.escapeShellArg cfg.tagline}
    $occ theming:config primary_color ${lib.escapeShellArg c.primary}
    $occ theming:config background_color ${lib.escapeShellArg c.deep}
    $occ theming:config background backgroundColor
    $occ theming:config logo ${cfg.logo}
    $occ theming:config favicon ${cfg.logo}
  '';
in
{
  options.tidepool.brand = {
    enable = lib.mkOption { type = lib.types.bool; default = true; description = "The brand where a program has a setting for it. On by default (the placeholder identity, or the one in `file`); `false` leaves every program as it comes."; };
    file = lib.mkOption { type = lib.types.path; default = ../brand/brand.json; description = "The brand as JSON (see nixos/brand/README.md). Fields it leaves out keep the defaults; `logo` and `wordmark` name files next to it."; };
    name = lib.mkOption { type = lib.types.str; default = data.name; defaultText = "from the file"; description = "The name of the service, shown where the programs let a name be set."; };
    slug = lib.mkOption { type = lib.types.strMatching "[a-z0-9-]+"; default = lib.replaceStrings [ " " ] [ "-" ] (lib.toLower cfg.name); defaultText = "the name in lower case, spaces as hyphens"; description = "The name where a host name or an identifier is needed."; };
    tagline = lib.mkOption { type = lib.types.str; default = data.tagline; defaultText = "from the file"; description = "A few words under the name."; };
    colors = lib.genAttrs [ "deep" "primary" "primaryOnDark" "accent" "sand" "text" ] (n: lib.mkOption { type = lib.types.strMatching "#[0-9a-fA-F]{6}"; default = data.colors.${n}; defaultText = "from the file"; description = "The ${n} colour, #rrggbb."; });
    logo = lib.mkOption { type = lib.types.path; default = fileOf "logo"; defaultText = "from the file"; description = "A square mark, SVG (Nextcloud's logo and favicon, the stylesheets of Immich and Jellyfin)."; };
    wordmark = lib.mkOption { type = lib.types.nullOr lib.types.path; default = fileOf "wordmark"; defaultText = "from the file"; description = "Optional: the mark with the name in outlined letters, for the wide places."; };
    out = lib.mkOption { type = lib.types.attrsOf lib.types.path; readOnly = true; default = { inherit jellyfinWebConfig jellyfinThemeDir; }; description = "What the module builds, for the checks."; };
    css = lib.mkOption { type = lib.types.attrsOf lib.types.str; readOnly = true; default = { immich = immichCss; }; description = "The stylesheet that a program takes in its own settings (other modules put it where the program reads it)."; };
  };
  config = lib.mkIf cfg.enable {
    system.nixos.distroName = cfg.name;
    users.motd = "${cfg.name}, ${cfg.tagline}";
    services.prometheus.extraFlags = [ (lib.escapeShellArg "--web.page-title=${cfg.name} metrics") ];   # the module joins the flags with spaces, unquoted
    systemd.services.nextcloud-brand = lib.mkIf config.services.nextcloud.enable {
      description = "Apply the brand to Nextcloud (its theming app keeps it in the database)";
      wantedBy = [ "multi-user.target" ]; after = [ "nextcloud-setup.service" ]; requires = [ "nextcloud-setup.service" ];
      restartTriggers = [ nextcloudBrand ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ExecStart = nextcloudBrand; };
    };
    virtualisation.oci-containers.containers.jellyfin = lib.mkIf config.tidepool.services.jellyfin.enable {
      extraOptions = [ "--hostname=${cfg.slug}" ];   # Jellyfin names itself after its host
      volumes = [ "${jellyfinWebConfig}:/jellyfin/jellyfin-web/config.json:ro" "${jellyfinThemeDir}:/jellyfin/jellyfin-web/themes/${cfg.slug}:ro" ];
    };
    systemd.tmpfiles.rules = lib.optional config.tidepool.services.jellyfin.enable "f+ /srv/data/jellyfin/config/config/branding.xml 0644 root root - ${jellyfinBranding}";
  };
}
