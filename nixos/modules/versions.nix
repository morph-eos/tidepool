# Version watch (ADR 0017): every weekend, a mail if an application runs an older release than upstream has had for a week, or its line is end of life.
# Deployed versions are read from the packages and image tags of THIS system generation (no script, no probing); upstream versions are read by json_exporter from
# endoflife.date (release lines: Nextcloud, PostgreSQL, nginx) or from GitHub (latest release: the others). The rules are in versions/rules.yml, with a promtool test.
{ config, lib, pkgs, ... }:
let
  inherit (lib) mapAttrsToList concatStringsSep filterAttrs;
  tag = image: builtins.head (builtins.match ".*:([^@:/]+)@sha256:.*" image);   # a container pin is "repo:tag@sha256:...", the tag says the version, the digest pins it
  image = name: config.virtualisation.oci-containers.containers.${name}.image;
  apps = {
    nextcloud   = { version = config.services.nextcloud.package.version; eol = "nextcloud"; cycle = lib.versions.major; };
    postgresql  = { version = config.services.postgresql.package.version; eol = "postgresql"; cycle = lib.versions.major; };
    nginx       = { version = config.services.nginx.package.version; eol = "nginx"; cycle = lib.versions.majorMinor; major = false; };   # 1.31 is the mainline line, not a "major" to adopt
    vaultwarden = { version = config.services.vaultwarden.package.version; github = "dani-garcia/vaultwarden"; repology = "vaultwarden"; };
    syncthing   = { version = config.services.syncthing.package.version; github = "syncthing/syncthing"; repology = "syncthing"; };
    borgbackup  = { version = pkgs.borgbackup.version; github = "borgbackup/borg"; repology = "borgbackup"; };
    pgbackrest  = { version = pkgs.pgbackrest.version; github = "pgbackrest/pgbackrest"; repology = "pgbackrest"; };
    immich      = { version = lib.removePrefix "v" (tag (image "immich-server")); github = "immich-app/immich"; };
    # the base system: the kernel, ZFS, the container engine and Incus; their new lines (7.2, 2.5, ...) are not "majors" to adopt, so only the patch and the end of life are watched
    linux       = { version = config.boot.kernelPackages.kernel.version; eol = "linux"; cycle = lib.versions.majorMinor; major = false; };
    openzfs     = { version = config.boot.zfs.package.version; eol = "openzfs"; cycle = lib.versions.majorMinor; major = false; };
    podman      = { version = pkgs.podman.version; eol = "podman"; cycle = lib.versions.majorMinor; major = false; repology = "podman"; };
    # Incus is NOT watched: it runs the LTS line (7.0.x) and GitHub's "latest release" is the feature line (7.5.x); a line-aware source is missing (the Incus LTS is announced on its own site)
  } // lib.optionalAttrs config.tidepool.nas.enable {
    samba       = { version = config.services.samba.package.version; eol = "samba"; cycle = lib.versions.majorMinor; major = false; repology = "samba"; };
  } // lib.optionalAttrs config.tidepool.push.enable {
    ntfy        = { version = config.services.ntfy-sh.package.version; github = "binwiederhier/ntfy"; repology = "ntfy-binwiederhier"; };
  } // lib.optionalAttrs config.tidepool.services.jellyfin.enable {
    jellyfin    = { version = tag (image "jellyfin"); github = "jellyfin/jellyfin"; };
  };
  eolApps = filterAttrs (_: a: a ? eol) apps;
  ghApps = filterAttrs (_: a: a ? github) apps;
  repoApps = filterAttrs (_: a: a ? repology) apps;   # the apps whose version also comes from nixpkgs: Repology says what the stable branch has
  branch = "nix_stable_${builtins.replaceStrings [ "." ] [ "_" ] config.system.nixos.release}";
  line = a: a.cycle a.version;
  textfile = concatStringsSep "\n" (lib.concatLists (mapAttrsToList (n: a:
    [ ''tidepool_deployed_info{app="${n}",version="${a.version}",source="${if a ? eol then "eol" else "github"}"${lib.optionalString (a ? eol) '',cycle="${line a}"''}} 1'' ]
    ++ lib.optional (a ? eol && (a.major or true)) ''tidepool_deployed_cycle{app="${n}"} ${line a}'') apps)) + "\n";
  jsonConfig = pkgs.writeText "json-exporter.yml" (builtins.toJSON { modules = {
    eol.metrics = [ {
      name = "tidepool_upstream_cycle"; type = "object"; help = "newest release of each release line (endoflife.date)";
      path = "{.result.releases[*]}";
      labels = { cycle = "{.name}"; version = "{.latest.name}"; eol = "{.isEol}"; };
      values = { latest = "1"; number = "{.name}"; };
    } ];
    github.metrics = [ {
      name = "tidepool_upstream_latest"; type = "object"; help = "latest release (GitHub)";
      path = "{}"; labels = { version = "{.tag_name}"; prerelease = "{.prerelease}"; };
      values = { latest = "1"; };
    } ];
    # what the stable nixpkgs branch has (Repology asks for a name that says who is asking; the filter is on the branch, the rules pick the package by its version)
    repology = { headers.User-Agent = "tidepool home server (version watch, one request an hour)"; metrics = [ {
      name = "tidepool_nixpkgs_latest"; type = "object"; help = "version on the stable nixpkgs branch (Repology)";
      path = ''{[?(@.repo=="${branch}")]}''; labels = { version = "{.version}"; srcname = "{.srcname}"; };
      values = { latest = "1"; };
    } ]; };
  }; });
  scrape = name: module: urls: {
    job_name = name; metrics_path = "/probe"; params.module = [ module ];
    scrape_interval = "1h"; scrape_timeout = "30s";   # GitHub allows 60 requests an hour without a login; this is a handful a day
    static_configs = mapAttrsToList (app: url: { targets = [ url ]; labels = { inherit app; }; }) urls;
    relabel_configs = [ { source_labels = [ "__address__" ]; target_label = "__param_target"; } { source_labels = [ "__address__" ]; target_label = "instance"; } { target_label = "__address__"; replacement = "127.0.0.1:7979"; } ];
  };
in
{
  environment.etc."tidepool/metrics/versions.prom".text = textfile;
  services.prometheus = {
    exporters.node.extraFlags = [ "--collector.textfile.directory=/etc/tidepool/metrics" ];
    exporters.json = { enable = true; listenAddress = "127.0.0.1"; port = 7979; configFile = jsonConfig; };
    ruleFiles = [ ./versions/rules.yml ];
    scrapeConfigs = [
      (scrape "upstream-eol" "eol" (lib.mapAttrs (_: a: "https://endoflife.date/api/v1/products/${a.eol}") eolApps))
      (scrape "upstream-github" "github" (lib.mapAttrs (_: a: "https://api.github.com/repos/${a.github}/releases/latest") ghApps))
      (scrape "upstream-nixpkgs" "repology" (lib.mapAttrs (_: a: "https://repology.org/api/v1/project/${a.repology}") repoApps))
    ];
  };
}
