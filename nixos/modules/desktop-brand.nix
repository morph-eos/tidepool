# The brand on the TV session (ADR 0020 for the brand, ADR 0022 for the session): the wallpaper, GNOME's dark style and accent colour, Firefox's start page and bookmarks,
# all made from the same brand.json (name, tagline, six colours, logo) as every other place, so a private repository that changes the brand changes this too.
# Only where a program has a setting for it (GNOME's dconf, Firefox's enterprise policies): no program's own files are patched. On when the TV session and the brand are both on.
{ config, lib, pkgs, ... }:
let
  cfg = config.tidepool;
  b = cfg.brand;
  c = b.colors;
  d = cfg.domain;
  vhosts = config.services.nginx.virtualHosts;

  hex2 = n: let h = lib.toHexString n; in lib.toLower (if builtins.stringLength h == 1 then "0${h}" else h);
  chan = hex: i: lib.fromHexString (builtins.substring i 2 (lib.removePrefix "#" hex));
  mix = base: other: t: "#" + lib.concatMapStrings (i: hex2 (builtins.floor ((chan base i) * (1.0 - t) + (chan other i) * t + 0.5))) [ 0 2 4 ];   # as in brand.nix

  # GNOME takes its accent colour from nine named ones (libadwaita's): the one nearest to the brand's primary colour
  accents = { blue = "#3584e4"; teal = "#2190a4"; green = "#3a944a"; yellow = "#c88800"; orange = "#ed5b00"; red = "#e62d42"; pink = "#d56199"; purple = "#9141ac"; slate = "#6f8396"; };
  dist = x: y: lib.foldl' (s: i: let e = (chan x i) - (chan y i); in s + e * e) 0 [ 0 2 4 ];
  accent = (lib.foldl' (best: n: let k = dist c.primary accents.${n}; in if k < best.k then { inherit n k; } else best) { n = "blue"; k = 1000000; } (lib.attrNames accents)).n;

  dataUri = file: "data:image/svg+xml," + lib.escapeURL (lib.replaceStrings [ "\n" ] [ " " ] (builtins.readFile file));
  name = lib.escapeXML b.name;
  tagline = lib.escapeXML b.tagline;

  # the wallpaper: the deep colour with a glow behind the mark, the name under it, and three layers of waves (the mark's own motif) along the bottom; an SVG, so it fits any screen
  # (the name is live text in a generic sans-serif font here: a wordmark with outlined letters, when the brand has one, takes its place)
  centre =
    if b.wordmark != null
    then ''<image href="${dataUri b.wordmark}" x="560" y="400" width="800" height="240"/>''
    else ''
      <image href="${dataUri b.logo}" x="810" y="290" width="300" height="300"/>
      <text x="960" y="690" text-anchor="middle" font-family="sans-serif" font-size="68" font-weight="600" fill="${c.sand}">${name}</text>
      <text x="960" y="750" text-anchor="middle" font-family="sans-serif" font-size="30" fill="${c.primaryOnDark}">${tagline}</text>'';
  wallpaper = pkgs.writeText "${b.slug}-wallpaper.svg" ''
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1920 1080" preserveAspectRatio="xMidYMid slice">
      <defs>
        <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${mix c.deep "#000000" 0.4}"/><stop offset="1" stop-color="${c.deep}"/></linearGradient>
        <radialGradient id="glow" cx="50%" cy="40%" r="42%"><stop offset="0" stop-color="${c.primary}" stop-opacity=".5"/><stop offset="1" stop-color="${c.primary}" stop-opacity="0"/></radialGradient>
      </defs>
      <rect width="1920" height="1080" fill="url(#sky)"/>
      <rect width="1920" height="1080" fill="url(#glow)"/>
      <path d="M0 830 C 240 770 480 890 720 830 S 1200 770 1440 830 S 1800 890 1920 830 V1080 H0 Z" fill="${c.primary}" fill-opacity=".32"/>
      <path d="M0 910 C 260 850 520 970 780 910 S 1280 850 1540 910 S 1800 970 1920 930 V1080 H0 Z" fill="${c.primaryOnDark}" fill-opacity=".16"/>
      <path d="M0 985 C 300 935 600 1035 900 985 S 1500 935 1920 995 V1080 H0 Z" fill="${c.deep}" fill-opacity=".7"/>
      ${centre}
    </svg>
  '';

  # Firefox's start page: the services that exist on this machine (a name is shown only when nginx has its virtual host), in the brand's colours. A local file: no server, no network
  present = lib.filterAttrs (_: sub: vhosts ? "${sub}.${d}") cfg.desktop.startPage.links;
  tile = label: sub: ''<a class="tile" href="https://${sub}.${d}/"><span>${lib.escapeXML label}</span><small>${sub}.${d}</small></a>'';
  startPage = pkgs.writeTextDir "index.html" ''
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"><title>${name}</title><meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      :root { color-scheme: dark; }
      body { margin: 0; min-height: 100vh; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 2.5rem; font-family: sans-serif; color: ${c.sand};
             background: radial-gradient(ellipse at 50% 30%, ${c.primary}66 0%, transparent 60%), linear-gradient(${mix c.deep "#000000" 0.4}, ${c.deep}); }
      header { text-align: center; } header img { width: 96px; height: 96px; } h1 { margin: .4rem 0 0; font-size: 2.6rem; } p { margin: .2rem 0 0; color: ${c.primaryOnDark}; font-size: 1.2rem; }
      nav { display: flex; flex-wrap: wrap; gap: 1.2rem; justify-content: center; padding: 0 2rem; }
      .tile { display: flex; flex-direction: column; gap: .3rem; min-width: 11rem; padding: 1.4rem 1.6rem; border-radius: 1rem; text-decoration: none; color: ${c.sand};
              background: ${c.primary}33; border: 1px solid ${c.primaryOnDark}55; }
      .tile:hover, .tile:focus { background: ${c.primary}88; border-color: ${c.accent}; outline: none; }
      .tile span { font-size: 1.5rem; font-weight: 600; } .tile small { color: ${c.primaryOnDark}; }
    </style></head>
    <body><header><img src="${dataUri b.logo}" alt=""><h1>${name}</h1><p>${tagline}</p></header>
    <nav>${lib.concatStrings (lib.mapAttrsToList tile present)}</nav></body></html>
  '';
  startUrl = "file://${startPage}/index.html";
in
{
  options.tidepool.desktop.startPage.links = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { Photos = "photos"; Cloud = "cloud"; Media = "media"; Passwords = "vault"; };
    description = "The tiles of the TV session's start page and the bookmarks of its browser: a label and the name's first part (`photos` for photos.<domain>). A name that no virtual host answers to is left out; a private repository adds its own (`{ Wiki = \"wiki\"; }`).";
  };

  config = lib.mkIf (cfg.desktop.enable && b.enable) {
    programs.dconf.profiles.user.databases = [{
      settings = {
        "org/gnome/desktop/background" = { picture-uri = "file://${wallpaper}"; picture-uri-dark = "file://${wallpaper}"; picture-options = "zoom"; primary-color = c.deep; secondary-color = c.deep; };
        "org/gnome/desktop/screensaver" = { picture-uri = "file://${wallpaper}"; primary-color = c.deep; };
        "org/gnome/desktop/interface" = { color-scheme = "prefer-dark"; accent-color = accent; };
      };
    }];

    programs.firefox.policies = {
      Homepage = { URL = startUrl; StartPage = "homepage"; Locked = false; };
      DisplayBookmarksToolbar = "always";
      ManagedBookmarks = [{ toplevel_name = b.name; }] ++ lib.mapAttrsToList (label: sub: { name = label; url = "https://${sub}.${d}/"; }) present;
      OverrideFirstRunPage = "";
      OverridePostUpdatePage = "";
      DontCheckDefaultBrowser = true;
      DisableTelemetry = true;
      NoDefaultBookmarks = true;
    };

    # the name the session shows for the machine (Settings, About); the host name itself stays what the configuration says
    environment.etc."machine-info".text = ''
      PRETTY_HOSTNAME="${lib.escape [ "\"" "\\" ] b.name}"
      ICON_NAME=computer
      CHASSIS=desktop
    '';
  };
}
