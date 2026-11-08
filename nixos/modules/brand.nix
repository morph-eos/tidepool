# The brand (docs/decisions/0020-brand-identity.md): one name, one palette, one logo (nixos/brand/brand.json and logo.svg), applied where a program has a setting for it:
# Nextcloud's theming, Jellyfin's themes and branding, Immich's configuration, Prometheus' title, the operating system's name, the mail's sender, Samba's name. No program's own files are patched or restyled from outside.
# The name of a service is the brand's name and a label ("Tidepool Cloud"): titles and tabs carry it, taglines and footers carry the brand's name alone; the labels and the text of the sign-in button are fields too.
# The data is JSON, so that tools that are not Nix can read it too. Another repository says `tidepool.brand.file = ./brand/brand.json;` (fields it leaves out keep the defaults), or sets single options.
{ config, lib, pkgs, ... }:
let
  cfg = config.tidepool.brand;
  labelNames = [ "cloud" "photos" "media" "track" "admin" "metrics" ];
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

  # Floppy has no setting for a palette that every user, and the sign-in page before any user, gets: its colours are CSS variables on the root element, a theme per user in its database. The edge adds this stylesheet to its pages
  # (floppy.nix; docs/exceptions.md), every variable `!important` so that a user's own theme cannot undo it. The same dark scale as Jellyfin's theme: the deep colour for the panels, lighter steps above it, the sand for the text, the colour on dark for the accent.
  floppyCss = let up = t: mix c.deep "#ffffff" t; down = t: mix c.deep "#000000" t; in ''
    html { color-scheme: dark;
      --color-page-bg: ${down 0.6} !important; --color-sidebar: ${down 0.7} !important; --color-panel: ${c.deep} !important;
      --color-surface: ${up 0.06} !important; --color-surface-strong: ${up 0.12} !important; --color-surface-hover: ${up 0.2} !important; --color-surface-alt: ${up 0.1} !important; --color-surface-muted: ${up 0.08} !important;
      --color-surface-dim: ${down 0.3} !important; --color-hover-dim: ${down 0.4} !important; --color-border: ${up 0.14} !important; --color-surface-border: ${up 0.22} !important;
      --color-text: ${c.sand} !important; --color-text-secondary: ${mix c.sand c.deep 0.12} !important; --color-text-muted: ${mix c.sand c.deep 0.25} !important;
      --color-accent: ${c.primaryOnDark} !important; --color-accent-contrast: ${c.deep} !important; --color-link: ${mix c.primaryOnDark "#ffffff" 0.25} !important; --color-link-hover: ${mix c.primaryOnDark "#ffffff" 0.45} !important;
      --color-genre-badge-bg: rgba(${lib.replaceStrings [ " " ] [ ", " ] (rgb c.primaryOnDark)}, 0.1) !important; --color-genre-badge-border: rgba(${lib.replaceStrings [ " " ] [ ", " ] (rgb c.primaryOnDark)}, 0.25) !important;
      --color-genre-badge-text: ${c.sand} !important; --color-genre-badge-hover-bg: rgba(${lib.replaceStrings [ " " ] [ ", " ] (rgb c.primaryOnDark)}, 0.2) !important;
      /* the buttons, borders and links of Floppy's own interface are Tailwind's indigo (utilities that read these variables, white text on the 500 to 700 steps): the brand's scale in their place, lightness for lightness */
      --color-indigo-200: ${mix c.primaryOnDark "#ffffff" 0.55} !important; --color-indigo-300: ${mix c.primaryOnDark "#ffffff" 0.25} !important; --color-indigo-400: ${c.primaryOnDark} !important;
      --color-indigo-500: ${c.primary} !important; --color-indigo-600: ${c.primary} !important; --color-indigo-700: ${mix c.primary "#000000" 0.2} !important; }
    img[src*="/floppy-logo"] { content: ${inline wide}; }
  '';

  # Jellyfin reads its branding from config/branding.xml: written whole (tmpfiles' f+ replaces the file; the escapes give the line breaks)
  jellyfinBranding = lib.replaceStrings [ "\n" "%" ] [ "\\n" "%%" ] ''<?xml version="1.0" encoding="utf-8"?>
<BrandingOptions><LoginDisclaimer>${lib.escapeXML cfg.name} - ${lib.escapeXML cfg.tagline}${lib.optionalString (cfg.jellyfinLoginHtml != "") (lib.escapeXML "<br>${cfg.jellyfinLoginHtml}")}</LoginDisclaimer><CustomCss>${lib.escapeXML jellyfinCss}</CustomCss><SplashscreenEnabled>false</SplashscreenEnabled></BrandingOptions>
'';
  nextcloudBrand = pkgs.writeShellScript "nextcloud-brand" ''
    occ=${config.services.nextcloud.occ}/bin/nextcloud-occ
    $occ theming:config name ${lib.escapeShellArg cfg.product.cloud}
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
    labels = lib.genAttrs labelNames (n: lib.mkOption { type = lib.types.str; default = data.labels.${n}; defaultText = "from the file"; description = "The word after the brand's name in the name of the ${n} service (`<name> <label>`); empty leaves the name alone."; });
    product = lib.mkOption { type = lib.types.attrsOf lib.types.str; readOnly = true; default = lib.genAttrs labelNames (n: lib.concatStringsSep " " (lib.filter (x: x != "") [ cfg.name cfg.labels.${n} ])); defaultText = "<name> <label>"; description = "The name of each service, `<name> <label>` (Tidepool Cloud): the title of a page and the tab, the name of the server or of the app where the program has one."; };
    signInLabel = lib.mkOption { type = lib.types.str; default = data.signInLabel; defaultText = "from the file"; description = "The text of the single sign-on button where a program shows one (Immich, Floppy, Jellyfin): generic, so that a page that is already the brand's does not say its name twice."; };
    tagline = lib.mkOption { type = lib.types.str; default = data.tagline; defaultText = "from the file"; description = "A few words under the name."; };
    colors = lib.genAttrs [ "deep" "primary" "primaryOnDark" "accent" "sand" "text" ] (n: lib.mkOption { type = lib.types.strMatching "#[0-9a-fA-F]{6}"; default = data.colors.${n}; defaultText = "from the file"; description = "The ${n} colour, #rrggbb."; });
    logo = lib.mkOption { type = lib.types.path; default = fileOf "logo"; defaultText = "from the file"; description = "A square mark, SVG (Nextcloud's logo and favicon, the stylesheets of Immich and Jellyfin)."; };
    wordmark = lib.mkOption { type = lib.types.nullOr lib.types.path; default = fileOf "wordmark"; defaultText = "from the file"; description = "Optional: the mark with the name in outlined letters, for the wide places."; };
    jellyfinLoginHtml = lib.mkOption { type = lib.types.str; default = lib.optionalString (config.tidepool.sso.enable && config.tidepool.sso.jellyfin.enable) ''<form action="/sso/OID/start/${config.tidepool.sso.jellyfin.provider}"><button class="raised block emby-button button-submit" type="submit">${lib.escapeXML cfg.signInLabel}</button></form>''; defaultText = "the button of the single sign-on when it is on for Jellyfin, nothing otherwise"; example = ''<form action="/sso/OID/start/provider"><button class="raised block emby-button button-submit">Sign in with the provider</button></form>''; description = "HTML added under the brand's line in Jellyfin's login message, which is where its single sign-on plugin has the button for its login page. With `tidepool.sso.jellyfin.enable` it is that button, with the text of `signInLabel`; set it to have something else. The file is written whole at each change of the system, so what is wanted there is declared here and not typed into Jellyfin's settings, where the next write would remove it."; };
    out = lib.mkOption { type = lib.types.attrsOf lib.types.path; readOnly = true; default = { inherit jellyfinWebConfig jellyfinThemeDir nextcloudBrand; }; description = "What the module builds, for the checks."; };
    css = lib.mkOption { type = lib.types.attrsOf lib.types.str; readOnly = true; default = { immich = immichCss; floppy = floppyCss; }; description = "The stylesheet that a program takes in its own settings (other modules put it where the program reads it); Floppy's is served by the edge, which adds it to the pages."; };
  };
  config = lib.mkIf cfg.enable {
    system.nixos.distroName = cfg.name;
    users.motd = "${cfg.name}, ${cfg.tagline}";
    services.prometheus.extraFlags = [ (lib.escapeShellArg "--web.page-title=${cfg.product.metrics}") ];   # the module joins the flags with spaces, unquoted
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
    # Jellyfin's tab and its apps show the server's name, which is its host name until a name is set in its settings file (config/system.xml). That file is the server's whole configuration and Jellyfin rewrites it itself, so it is not written whole: the one
    # element is set before each start, in the file as it is (the first start makes the file, the next one sets the name).
    systemd.services.podman-jellyfin = lib.mkIf config.tidepool.services.jellyfin.enable { preStart = ''
      f=/srv/data/jellyfin/config/config/system.xml
      want=${lib.escapeShellArg cfg.product.media}
      if [ -f "$f" ] && [ "$(${pkgs.xmlstarlet}/bin/xmlstarlet sel -T -t -v /ServerConfiguration/ServerName "$f")" != "$want" ]; then
        ${pkgs.xmlstarlet}/bin/xmlstarlet ed -L -d /ServerConfiguration/ServerName -s /ServerConfiguration -t elem -n ServerName -v "$want" "$f" || echo "Jellyfin's server name was not set"
      fi
    ''; };
    # Nextcloud's theming has one field for the name of the page, the tab and the app, and the footer of its login page repeats that same field before the tagline: with a service's name in it ("Tidepool Cloud – your own cloud") the footer is
    # corrected on its way out (docs/exceptions.md), to the brand's name alone (the name is a link in that footer, to the address the theming has; a footer without a link is not rewritten).
    assertions = lib.mapAttrsToList (k: v: { assertion = builtins.match "[^\"'$\\\\;]*" v != null; message = "tidepool.brand: the name or the ${k} label has a quote, a dollar sign, a semicolon or a backslash (it is written into a web server's configuration)"; }) (cfg.product // { name = cfg.name; });
    services.nginx.virtualHosts."cloud.${d}" = lib.mkIf (config.services.nextcloud.enable && cfg.product.cloud != cfg.name) {
      extraConfig = ''
        sub_filter "class=\"entity-name\">${cfg.product.cloud}</a>" "class=\"entity-name\">${cfg.name}</a>";
        sub_filter_once on;
      '';
      # Nextcloud compresses its pages for a client that accepts it, and nginx does not rewrite a body that is already compressed: the application is told the client takes no compression (nginx compresses the page itself, after the rewrite)
      locations."~ \\.php(?:$|/)".extraConfig = lib.mkAfter ''fastcgi_param HTTP_ACCEPT_ENCODING "";'';
    };
    # Immich writes its tab title in the browser, in one place of its web client: `${the page's title} - Immich`. No setting reaches it; the edge gives that one chunk (nodes/0.<hash>.js) the name of the service in place of the program's own (docs/exceptions.md).
    # The chunk's file name is cached by browsers as immutable: a browser that has the old one shows the old title until its cache is cleared (a hard reload).
    services.nginx.virtualHosts."photos.${d}".locations."~ ^/_app/immutable/nodes/0\\.[A-Za-z0-9_-]+\\.js$" = {
      proxyPass = "http://127.0.0.1:2283";
      extraConfig = ''
        proxy_set_header Accept-Encoding "";
        sub_filter_types application/javascript text/javascript;
        sub_filter ' - Immich`' ' - ${cfg.product.photos}`';
        sub_filter_once on;
      '';
    };
    systemd.tmpfiles.rules = lib.optional config.tidepool.services.jellyfin.enable "f+ /srv/data/jellyfin/config/config/branding.xml 0644 root root - ${jellyfinBranding}";
  };
}
