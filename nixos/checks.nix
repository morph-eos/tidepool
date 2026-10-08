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
  withAdmin = ext [ { tidepool.admin.enable = true; } ];

  # assertions about the brand and the single sign-on: the module system's merging (a file, a field, nothing), and the constraints the lab found (a client id of 32 to 64 characters)
  facts = {
    "the brand is on by default and the system carries its name" = base.tidepool.brand.name == "Tidepool" && base.system.nixos.distroName == "Tidepool";
    "the brand off leaves the system as it comes" = off.system.nixos.distroName == "NixOS" && !(off.systemd.services ? nextcloud-brand);
    "a brand file of another repository replaces the brand" = other.tidepool.brand.name == "Acme Home" && other.tidepool.brand.slug == "acme-home" && other.tidepool.brand.colors.primary == "#aa3355"
      && baseNameOf (toString other.tidepool.brand.logo) == "other-logo.svg" && other.system.nixos.distroName == "Acme Home";
    "a brand file with one field keeps the other defaults" = partial.tidepool.brand.name == "Partial Co" && partial.tidepool.brand.colors.deep == "#0b3c49" && partial.tidepool.brand.tagline == "your own cloud";
    "one option overrides one field" = single.tidepool.brand.name == "Solo Name" && single.tidepool.brand.slug == "solo-name" && single.tidepool.brand.colors.primary == "#0f7a8c";
    "Immich's declared settings carry the brand" = lib.hasInfix "--immich-primary" base.tidepool.services.immich.settings.theme.customCss && base.tidepool.services.immich.settings.server.externalDomain == "https://photos.${base.tidepool.domain}";
    "the single sign-on is off unless asked" = !(base.systemd.services ? nextcloud-oidc-clients) && !(base.tidepool.services.immich.settings ? oauth);
    "the single sign-on registers Immich, with a client id Nextcloud accepts (32 to 64 characters)" = withSso.systemd.services ? nextcloud-oidc-clients
      && (let n = lib.stringLength withSso.tidepool.services.immich.settings.oauth.clientId; in n >= 32 && n <= 64);
    "Immich's secret is a sops placeholder, never a value" = lib.hasPrefix "<SOPS:" withSso.tidepool.services.immich.settings.oauth.clientSecret && withSso.sops.secrets ? immich-oauth-secret;
    "the discovery document is answered where Immich asks" = withSso.services.nginx.virtualHosts."cloud.${withSso.tidepool.domain}".locations ? "= /.well-known/openid-configuration";
    "the admin page is off unless asked" = !base.services.homepage-dashboard.enable;
    "the admin page listens on the loopback and is served on the VPN address only" = withAdmin.systemd.services.homepage-dashboard.environment.HOSTNAME == "127.0.0.1"
      && lib.all (l: l.addr == "10.100.0.1") withAdmin.services.nginx.virtualHosts."admin.${withAdmin.tidepool.domain}".listen
      && withAdmin.services.homepage-dashboard.allowedHosts == "admin.${withAdmin.tidepool.domain}";
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
    pkgs.runCommand "brand" { nativeBuildInputs = [ pkgs.jq (pkgs.python3.withPackages (_: [ ])) ]; } ''
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
      # Jellyfin: the web config served is the image's, with the brand's theme the only default and the six built-in ones still offered
      cfg=${withJellyfin.tidepool.brand.out.jellyfinWebConfig}
      jq -e '([.themes[] | select(.default == true)] | length) == 1 and (.themes[] | select(.default == true) | .id) == "tidepool" and ([.themes[] | select(.id != "tidepool")] | length) == 6 and (.plugins | length) > 5' "$cfg" > /dev/null
      diff <(jq -S 'del(.themes)' "$cfg") <(jq -S 'del(.themes)' ${./brand/jellyfin-web-config.json})
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
    shellcheck -S warning -x private-repo-template/tools/*.sh .github/scripts/*.sh lab/gate.sh lab/smoke-test.sh lab/brand-test.sh lab/brand-check.sh lab/compute-names.sh
    touch $out
  '';

  # no secret in the tree (the rules are .gitleaks.toml)
  secrets-scan = pkgs.runCommand "secrets-scan" { nativeBuildInputs = [ pkgs.gitleaks ]; } ''
    cd ${root}   # the rules' paths are relative to the repository
    gitleaks detect --no-git --no-banner --source . --config .gitleaks.toml
    touch $out
  '';
}
