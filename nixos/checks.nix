# What `nix flake check` proves, on every pull request and on main (.github/workflows/check.yml). Everything here runs without booting a machine, in a few minutes; what needs a running
# machine is lab/gate.sh (run by hand before a push to main: lab/README.md).
{ self, nixpkgs }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  root = self.sourceInfo.outPath;   # the whole repository (the flake is in nixos/)
  ext = mods: (self.nixosConfigurations.lab.extendModules { modules = mods; }).config;
  fixture = f: ./brand/test + "/${f}";

  base = ext [ ];
  other = ext [ { tidepool.brand.file = fixture "other-brand.json"; } ];
  partial = ext [ { tidepool.brand.file = fixture "partial-brand.json"; } ];
  single = ext [ { tidepool.brand.name = "Solo Name"; } ];
  off = ext [ { tidepool.brand.enable = false; } ];
  withJellyfin = ext [ { tidepool.services.jellyfin = { enable = lib.mkForce true; mediaMounts = lib.mkForce { "/media" = "/tmp"; }; }; } ];
  withSso = ext [ { tidepool.sso.enable = true; } ];
  # another repository's brand on a host with every program that takes one running (Jellyfin is off in the lab)
  otherAll = ext [ { tidepool.brand.file = fixture "other-brand.json"; tidepool.services.jellyfin = { enable = lib.mkForce true; mediaMounts = lib.mkForce { "/media" = "/tmp"; }; }; } ];
  # a brand that names everything in its own words ("Pippo"), on a host with the single sign-on, Jellyfin and the TV session; and the name alone ("Pippo") with the default labels
  pippo = ext [ { tidepool.brand.file = fixture "pippo-brand.json"; tidepool.sso.enable = true; tidepool.sso.jellyfin.enable = true; tidepool.services.jellyfin = { enable = lib.mkForce true; mediaMounts = lib.mkForce { "/media" = "/tmp"; }; }; } ];
  pippoName = ext [ { tidepool.brand.name = "Pippo"; tidepool.services.jellyfin = { enable = lib.mkForce true; mediaMounts = lib.mkForce { "/media" = "/tmp"; }; }; } ];
  badName = (builtins.tryEval (ext [ { tidepool.brand.name = ''Pi"ppo''; } ]).system.build.toplevel.drvPath).success;
  # the brand file the private repository's template starts from works as it is
  fromTemplate = ext [ { tidepool.brand.file = "${root}/private-repo-template/brand/brand.json"; } ];
  pd = pippo.tidepool.domain;
  # Jellyfin's sign-in through Nextcloud: off by default; on, with the client declared, the plugin's settings made ready before the start and the button on the login page; and a client that exists under another id adopted
  jfSso = ext [ { tidepool.sso.enable = true; tidepool.sso.jellyfin.enable = true; tidepool.services.jellyfin = { enable = lib.mkForce true; mediaMounts = lib.mkForce { "/media" = "/tmp"; }; }; } ];
  jfAdopt = ext [ { tidepool.sso.enable = true; tidepool.sso.jellyfin = { enable = true; provider = "idp"; }; tidepool.sso.clients.jellyfin.clientId = "adopted-client-id-0123456789abcdef0123"; tidepool.services.jellyfin = { enable = lib.mkForce true; mediaMounts = lib.mkForce { "/media" = "/tmp"; }; }; } ];
    withAdmin = base;
  noAdmin = ext [ { tidepool.admin.enable = false; } ];
  noFloppy = ext [ { tidepool.services.floppy.enable = lib.mkForce false; } ];

  # assertions about the brand and the single sign-on: the module system's merging (a file, a field, nothing), and the constraints the lab found (a client id of 32 to 64 characters)
  facts = {
    "the brand is on by default and the system carries its name" = base.tidepool.brand.name == "Tidepool" && base.system.nixos.distroName == "Tidepool";
    "the brand off leaves the system as it comes" = off.system.nixos.distroName == "NixOS" && !(off.systemd.services ? nextcloud-brand);
    "a brand file of another repository replaces the brand" = other.tidepool.brand.name == "Acme Home" && other.tidepool.brand.slug == "acme-home" && other.tidepool.brand.colors.primary == "#aa3355"
      && baseNameOf (toString other.tidepool.brand.logo) == "other-logo.svg" && other.system.nixos.distroName == "Acme Home";
    "a brand of another repository reaches every program that takes one: Immich, the admin page, Prometheus, Samba, the alerts' sender, Jellyfin's login text, Floppy's logo" =
         lib.hasInfix "Acme Home" otherAll.tidepool.services.immich.settings.server.loginPageMessage && lib.hasInfix "170 51 85" otherAll.tidepool.services.immich.settings.theme.customCss
      && otherAll.services.homepage-dashboard.settings.title == "Acme Home Admin" && lib.hasInfix "#220011" otherAll.services.homepage-dashboard.customCSS
      && lib.any (lib.hasInfix "Acme Home Metrics") otherAll.services.prometheus.extraFlags
      && otherAll.services.samba.settings.global."server string" == "Acme Home NAS" && otherAll.services.samba.settings.global."netbios name" == "acme-home"
      && lib.hasInfix "Acme Home alerts" (builtins.toJSON otherAll.services.prometheus.alertmanager.configuration)
      && lib.any (lib.hasInfix "Acme Home - ours") otherAll.systemd.tmpfiles.rules
      && lib.hasInfix "floppy-logo" otherAll.tidepool.brand.css.floppy && otherAll.tidepool.brand.css.floppy != base.tidepool.brand.css.floppy;
    "every service is named <brand> <label>, the labels have defaults and a brand names its own" =
         base.tidepool.brand.product.cloud == "Tidepool Cloud" && base.tidepool.brand.product.photos == "Tidepool Photos" && base.tidepool.brand.product.media == "Tidepool Media" && base.tidepool.brand.product.track == "Tidepool Track"
      && base.tidepool.brand.product.admin == "Tidepool Admin" && base.tidepool.brand.product.metrics == "Tidepool Metrics"
      && pippoName.tidepool.brand.product.cloud == "Pippo Cloud" && pippoName.tidepool.brand.product.media == "Pippo Media" && pippoName.tidepool.brand.product.track == "Pippo Track"
      && pippo.tidepool.brand.product.cloud == "Pippo Nuvola" && pippo.tidepool.brand.product.photos == "Pippo Foto" && pippo.tidepool.brand.product.metrics == "Pippo Numeri";
    "the template's brand file is a working brand, with every field" = fromTemplate.tidepool.brand.name == "Example" && fromTemplate.tidepool.brand.product.cloud == "Example Cloud"
      && fromTemplate.tidepool.brand.signInLabel == "Sign in with SSO" && baseNameOf (toString fromTemplate.tidepool.brand.logo) == "logo.svg"
      && builtins.attrNames (builtins.fromJSON (builtins.readFile "${root}/private-repo-template/brand/brand.json")) == builtins.attrNames (builtins.fromJSON (builtins.readFile ./brand/brand.json));
    "a brand with an empty label names the service by the brand alone" = (ext [ { tidepool.brand.labels.cloud = ""; } ]).tidepool.brand.product.cloud == "Tidepool";
    "a name that would break the web server's configuration is refused" = !badName;
    "the title of the page is the service's name in every program that has one, a brand of another repository included" =
         lib.any (lib.hasInfix "--web.page-title=Pippo Numeri") pippo.services.prometheus.extraFlags && pippo.services.homepage-dashboard.settings.title == "Pippo Regia"
      && lib.hasInfix "- Pippo Diario" pippo.services.nginx.virtualHosts."track.${pd}".locations."/".extraConfig && lib.hasInfix "content=\"Pippo Diario\"" pippo.services.nginx.virtualHosts."track.${pd}".locations."/accounts/".extraConfig
      && lib.hasInfix "want='Pippo Film'" pippo.systemd.services.podman-jellyfin.preStart
      && lib.hasInfix ''class=\"entity-name\">Pippo Nuvola</a>" "class=\"entity-name\">Pippo</a>'' pippo.services.nginx.virtualHosts."cloud.${pd}".extraConfig
      && pippoName.services.homepage-dashboard.settings.title == "Pippo Admin";
    "a footer, a banner and a tagline carry the brand's name and no service's" =
         pippo.tidepool.services.immich.settings.server.loginPageMessage == "Pippo, casa nostra" && lib.any (lib.hasInfix "Pippo - casa nostra&lt;br&gt;") pippo.systemd.tmpfiles.rules
      && !(lib.any (lib.hasInfix "Pippo Film - ") pippo.systemd.tmpfiles.rules) && base.services.nginx.virtualHosts."cloud.${base.tidepool.domain}".extraConfig != "" && !(lib.hasInfix "entity-name" off.services.nginx.virtualHosts."cloud.${off.tidepool.domain}".extraConfig);
    "the text of the sign-in button is the brand's field, in Immich and in Floppy, and a generic default" =
         pippo.tidepool.services.immich.settings.oauth.buttonText == "Entra con Pippo" && lib.hasInfix "Entra con Pippo" pippo.sops.templates."floppy-sso.env".content
      && withSso.tidepool.services.immich.settings.oauth.buttonText == "Sign in with SSO" && lib.hasInfix "Sign in with SSO" withSso.sops.templates."floppy-sso.env".content
      && !(lib.hasInfix "Login with" withSso.tidepool.services.immich.settings.oauth.buttonText);
    "Jellyfin's sign-in through Nextcloud is off unless asked, and on it declares the client and writes the button" =
         !(base.systemd.services ? podman-jellyfin)   # Jellyfin off: no unit of it, not even an empty one
      && !(withJellyfin.tidepool.sso.clients ? jellyfin) && withJellyfin.tidepool.brand.jellyfinLoginHtml == ""
      && jfSso.tidepool.sso.clients ? jellyfin && jfSso.tidepool.sso.clients.jellyfin.redirectUris == [ "https://media.${jfSso.tidepool.domain}/sso/OID/redirect/nextcloud" ] && jfSso.sops.secrets ? jellyfin-oauth-secret
      && lib.hasInfix "/sso/OID/start/nextcloud" jfSso.tidepool.brand.jellyfinLoginHtml && lib.hasInfix "Sign in with SSO" jfSso.tidepool.brand.jellyfinLoginHtml && !(lib.hasInfix "Nextcloud" jfSso.tidepool.brand.jellyfinLoginHtml)
      && lib.hasInfix "Entra con Pippo</button>" pippo.tidepool.brand.jellyfinLoginHtml
      && lib.hasInfix "/sso/OID/start/idp" jfAdopt.tidepool.brand.jellyfinLoginHtml && jfAdopt.tidepool.sso.clients.jellyfin.redirectUris == [ "https://media.${jfAdopt.tidepool.domain}/sso/OID/redirect/idp" ];
    "a brand file with one field keeps the other defaults" = partial.tidepool.brand.name == "Partial Co" && partial.tidepool.brand.colors.deep == "#0b3c49" && partial.tidepool.brand.tagline == "your own cloud";
    "one option overrides one field" = single.tidepool.brand.name == "Solo Name" && single.tidepool.brand.slug == "solo-name" && single.tidepool.brand.colors.primary == "#0f7a8c";
    "Immich's declared settings carry the brand" = lib.hasInfix "--immich-primary" base.tidepool.services.immich.settings.theme.customCss && base.tidepool.services.immich.settings.server.externalDomain == "https://photos.${base.tidepool.domain}";
    "the single sign-on is off unless asked" = !(base.systemd.services ? nextcloud-oidc-clients) && !(base.tidepool.services.immich.settings ? oauth);
    "the single sign-on registers Immich, with a client id Nextcloud accepts (32 to 64 characters)" = withSso.systemd.services ? nextcloud-oidc-clients
      && (let n = lib.stringLength withSso.tidepool.services.immich.settings.oauth.clientId; in n >= 32 && n <= 64);
    "Immich's secret is a sops placeholder, never a value" = lib.hasPrefix "<SOPS:" withSso.tidepool.services.immich.settings.oauth.clientSecret && withSso.sops.secrets ? immich-oauth-secret;
    "the discovery document is answered where Immich asks" = withSso.services.nginx.virtualHosts."cloud.${withSso.tidepool.domain}".locations ? "= /.well-known/openid-configuration";
    "the admin page is on by default and can be left out" = base.services.homepage-dashboard.enable && !noAdmin.services.homepage-dashboard.enable && !(noAdmin.services.nginx.virtualHosts ? "admin.${noAdmin.tidepool.domain}");
    "the admin page listens on the loopback and is served on the VPN address only" = withAdmin.systemd.services.homepage-dashboard.environment.HOSTNAME == "127.0.0.1"
      && lib.all (l: l.addr == "10.100.0.1") withAdmin.services.nginx.virtualHosts."admin.${withAdmin.tidepool.domain}".listen
      && withAdmin.services.homepage-dashboard.allowedHosts == "admin.${withAdmin.tidepool.domain}";
    "Floppy is a container pinned by digest, told the number of the user the machine makes for it" = lib.hasInfix "@sha256:" base.virtualisation.oci-containers.containers.floppy.image
      && base.virtualisation.oci-containers.containers.floppy.environment.PUID == toString base.users.users.tracker.uid;
    "Floppy's database role is reached by its container's two users and no other" = lib.hasInfix "floppy root floppy" base.services.postgresql.identMap && lib.hasInfix "floppy tracker floppy" base.services.postgresql.identMap
      && !(lib.hasInfix "floppy nginx" base.services.postgresql.identMap);
    "Floppy off leaves no trace" = !(noFloppy.virtualisation.oci-containers.containers ? floppy) && !(noFloppy.virtualisation.oci-containers.containers ? floppy-redis) && !(noFloppy.services.nginx.virtualHosts ? "track.${noFloppy.tidepool.domain}")
      && !(lib.hasInfix "floppy" noFloppy.services.postgresql.identMap) && !(noFloppy.users.users ? tracker) && !(noFloppy.tidepool.sso.clients ? floppy);
    "the single sign-on registers Floppy, with its secret as a sops placeholder, and the edge refuses the sign-up form" = withSso.tidepool.sso.clients ? floppy && withSso.sops.secrets ? floppy-oauth-secret
      && lib.hasInfix "<SOPS:" withSso.sops.templates."floppy-sso.env".content && withSso.services.nginx.virtualHosts."track.${withSso.tidepool.domain}".locations ? "= /accounts/signup/";
    "Floppy's pages carry the brand's stylesheet, forced, and the brand off leaves them as they come" = lib.hasInfix "--color-accent: ${base.tidepool.brand.colors.primaryOnDark} !important" base.tidepool.brand.css.floppy
      && lib.hasInfix "/_brand/theme.css" base.services.nginx.virtualHosts."track.${base.tidepool.domain}".locations."/".extraConfig && base.services.nginx.virtualHosts."track.${base.tidepool.domain}".locations ? "= /_brand/theme.css"
      && !(off.services.nginx.virtualHosts."track.${off.tidepool.domain}".locations ? "= /_brand/theme.css") && !(lib.hasInfix "sub_filter" off.services.nginx.virtualHosts."track.${off.tidepool.domain}".locations."/".extraConfig)
      && lib.hasInfix other.tidepool.brand.colors.primaryOnDark other.tidepool.brand.css.floppy && other.tidepool.brand.colors.primaryOnDark != base.tidepool.brand.colors.primaryOnDark;
    "Jellyfin gets its theme mounted when it runs" = lib.any (v: lib.hasInfix "jellyfin-web/config.json" v) withJellyfin.virtualisation.oci-containers.containers.jellyfin.volumes;
  };
  failing = lib.attrNames (lib.filterAttrs (_: ok: !ok) facts);
in
{
  lab = self.nixosConfigurations.lab.config.system.build.toplevel;
  tidepool = self.nixosConfigurations.tidepool.config.system.build.toplevel;

  # the version-watch rules (ADR 0017) against their unit test: 11 days of synthetic series, the alerts must fire on a weekend and only when a week is complete
  versions-rules = pkgs.runCommand "versions-rules" { nativeBuildInputs = [ pkgs.prometheus.cli ]; } ''
    cp ${./modules/versions}/rules.yml ${./modules/versions}/rules.test.yml .
    promtool check rules rules.yml
    promtool test rules rules.test.yml
    touch $out
  '';

  brand = assert lib.assertMsg (failing == [ ]) "brand and single sign-on: these fail: ${lib.concatStringsSep "; " failing}";
    pkgs.runCommand "brand" { nativeBuildInputs = [ pkgs.jq pkgs.xmlstarlet pkgs.perl (pkgs.python3.withPackages (_: [ ])) ]; } ''
      # the default palette keeps the contrasts the documents promise (WCAG), and nobody pairs white with the accent
      python3 - ${./brand/brand.json} <<'PY'
      import json, sys
      c = json.load(open(sys.argv[1]))["colors"]
      def lum(h):
          r, g, b = [int(h[i:i+2], 16) / 255 for i in (1, 3, 5)]
          f = lambda v: v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
          return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
      def ratio(a, b):
          x, y = sorted([lum(a), lum(b)], reverse=True); return (x + 0.05) / (y + 0.05)
      need = [("#ffffff", c["primary"], 4.5), (c["text"], c["sand"], 7.0), (c["sand"], c["deep"], 7.0), (c["primaryOnDark"], c["deep"], 4.5), (c["text"], c["accent"], 4.5)]
      bad = [(a, b, round(ratio(a, b), 2), m) for a, b, m in need if ratio(a, b) < m]
      assert not bad, f"contrast too low: {bad}"
      print("contrasts hold")
      PY
      # Floppy's stylesheet is derived from the palette: the pairs of its own tokens that carry text keep their contrast (WCAG AA, 4.5)
      python3 - ${pkgs.writeText "floppy-brand.css" base.tidepool.brand.css.floppy} <<'PY'
      import re, sys
      v = dict(re.findall(r"--color-([a-z0-9-]+): (#[0-9a-f]{6}) !important", open(sys.argv[1]).read()))
      def lum(h):
          r, g, b = [int(h[i:i+2], 16) / 255 for i in (1, 3, 5)]
          f = lambda x: x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4
          return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
      def ratio(a, b):
          x, y = sorted([lum(a), lum(b)], reverse=True); return (x + 0.05) / (y + 0.05)
      bgs = ["page-bg", "panel", "surface", "surface-strong", "surface-alt", "surface-muted", "sidebar"]
      v["white"] = "#ffffff"
      need = [(t, b) for t in ("text", "text-secondary", "text-muted", "link") for b in bgs] + [("accent-contrast", "accent")] \
           + [("white", i) for i in ("indigo-500", "indigo-600", "indigo-700")] + [(i, b) for i in ("indigo-300", "indigo-400") for b in ("page-bg", "panel", "surface")]
      bad = [(t, b, round(ratio(v[t], v[b]), 2)) for t, b in need if ratio(v[t], v[b]) < 4.5]
      assert not bad, f"Floppy's palette: contrast too low: {bad}"
      print("Floppy's contrasts hold")
      PY
      # Jellyfin: the web config served is the image's, with the brand's theme the only default and the six built-in ones still offered
      cfg=${withJellyfin.tidepool.brand.out.jellyfinWebConfig}
      jq -e '([.themes[] | select(.default == true)] | length) == 1 and (.themes[] | select(.default == true) | .id) == "tidepool" and ([.themes[] | select(.id != "tidepool")] | length) == 6 and (.plugins | length) > 5' "$cfg" > /dev/null
      diff <(jq -S 'del(.themes)' "$cfg") <(jq -S 'del(.themes)' ${./brand/jellyfin-web-config.json})
      # the script that points Jellyfin's sign-in plugin at Nextcloud: writes a file that is not there, leaves a provider that differs alone, updates four fields under --adopt and keeps the rest, adds a second provider; the secret is read from a file
      t=$(mktemp -d); sc=${./jellyfin/sso/sso-config.sh}; printf 'Sekret&<1>\n' > $t/s1; printf 'other&\n' > $t/s2
      a="--config-dir $t/c --provider nextcloud --endpoint https://cloud.example.org"
      rc=0; bash $sc $a --client-id cid-1 --secret-file $t/s1 --check >/dev/null || rc=$?; [ $rc = 10 ]
      bash $sc $a --client-id cid-1 --secret-file $t/s1 >/dev/null; xmlstarlet val -e $t/c/SSO-Auth.xml >/dev/null; [ "$(stat -c %a $t/c/SSO-Auth.xml)" = 600 ]
      bash $sc $a --client-id cid-1 --secret-file $t/s1 --check | grep -q "nothing to do"
      rc=0; bash $sc $a --client-id cid-2 --secret-file $t/s2 >/dev/null || rc=$?; [ $rc = 3 ]
      [ "$(xmlstarlet sel -T -t -v //OidClientId $t/c/SSO-Auth.xml)" = cid-1 ]
      perl -0pi -e 's{<CanonicalLinks />}{<CanonicalLinks><item><key><string>bob</string></key><value><guid>11111111-2222-3333-4444-555555555555</guid></value></item></CanonicalLinks>}' $t/c/SSO-Auth.xml
      bash $sc $a --client-id cid-2 --secret-file $t/s2 --adopt >/dev/null; xmlstarlet val -e $t/c/SSO-Auth.xml >/dev/null
      [ "$(xmlstarlet sel -T -t -v //OidClientId $t/c/SSO-Auth.xml)" = cid-2 ] && [ "$(xmlstarlet sel -T -t -v //OidSecret $t/c/SSO-Auth.xml)" = 'other&' ] && grep -q 11111111-2222 $t/c/SSO-Auth.xml
      bash $sc --config-dir $t/c --provider second --endpoint https://x.example.org --client-id c3 --secret-file $t/s2 >/dev/null; [ "$(xmlstarlet sel -t -v 'count(//OidConfigs/item)' $t/c/SSO-Auth.xml)" = 2 ]
      echo "Jellyfin's sign-in settings script holds"
      # Nextcloud's theming gets the service's name (the title, the tab and the app), the tagline stays the tagline
      grep -q "theming:config name 'Pippo Nuvola'" ${pippo.tidepool.brand.out.nextcloudBrand}
      grep -q "theming:config slogan 'casa nostra'" ${pippo.tidepool.brand.out.nextcloudBrand}
      grep -q "theming:config name 'Tidepool Cloud'" ${base.tidepool.brand.out.nextcloudBrand}
      # the same for another repository's brand: its theme is the default one and carries its colours
      cfg2=${otherAll.tidepool.brand.out.jellyfinWebConfig}
      jq -e '(.themes[] | select(.default == true) | .name) == "Acme Home" and (.themes[] | select(.default == true) | .color) == "#220011"' "$cfg2" > /dev/null
      grep -q '#ff8fa8' ${otherAll.tidepool.brand.out.jellyfinThemeDir}/theme.css
      touch $out
    '';

  # the documents hold together (links, scripts, indexes, one list of what is left)
  docs = pkgs.runCommand "docs" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    python3 ${root}/.github/scripts/check-docs.py ${root}
    touch $out
  '';

  # the template of the private repository works: its tools make the secrets, say what is left, add a VPN device
  template = pkgs.runCommand "template" { nativeBuildInputs = [ pkgs.sops pkgs.age pkgs.wireguard-tools pkgs.openssl pkgs.openssh pkgs.jq pkgs.bash (pkgs.python3.withPackages (ps: [ ps.bcrypt ])) ]; } ''
    bash ${root}/.github/scripts/check-template.sh ${root}/private-repo-template
    touch $out
  '';

  # the shell that is meant to be run (the template's tools, the CI's scripts, the gate and the lab checks it runs): no warning from shellcheck
  shell = pkgs.runCommand "shell" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
    cd ${root}
    shellcheck -S warning -x nixos/floppy/jellyfin-link/*.sh nixos/jellyfin/sso/*.sh private-repo-template/tools/*.sh .github/scripts/*.sh lab/gate.sh lab/smoke-test.sh lab/brand-test.sh lab/brand-check.sh lab/compute-names.sh
    touch $out
  '';

  # no secret in the tree (the rules are .gitleaks.toml)
  secrets-scan = pkgs.runCommand "secrets-scan" { nativeBuildInputs = [ pkgs.gitleaks ]; } ''
    cd ${root}   # the rules' paths are relative to the repository
    gitleaks detect --no-git --no-banner --source . --config .gitleaks.toml
    touch $out
  '';
}
