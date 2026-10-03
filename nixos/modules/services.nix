# The services (ADR 0011): native NixOS modules where the module is current (Nextcloud, Vaultwarden, Syncthing, smartd, nginx WebDAV), pinned containers under Podman where it is not (Immich, Jellyfin).
# All state is under /srv/data (one ZFS dataset, backed up by Borg); every database is in PostgreSQL over its Unix socket.
{ config, lib, pkgs, ... }:
let
  cfg = config.tidepool;
  d = cfg.domain;
  dbEnv = { DB_HOSTNAME = "/run/postgresql"; DB_USERNAME = "postgres"; DB_PASSWORD = "unused-peer-auth"; DB_DATABASE_NAME = "immich"; REDIS_HOSTNAME = "127.0.0.1"; };
in
{
  services.nextcloud = {
    enable = true;
    package = pkgs.nextcloud33;
    hostName = "cloud.${d}";
    https = true;
    home = "/srv/data/nextcloud";
    maxUploadSize = "50G";
    configureRedis = true;
    database.createLocally = true;   # the module creates the role and database and orders itself after them
    config = { dbtype = "pgsql"; adminpassFile = config.sops.secrets.nextcloud-admin-pass.path; };
    extraApps = { inherit (pkgs.nextcloud33Packages.apps) oidc; };   # Nextcloud as the single sign-on provider: the app is declared, the clients are created by `occ oidc:create` (exceptions.md, planned entry)
    extraAppsEnable = true;
  };

  services.vaultwarden = {
    enable = true;
    dbBackend = "postgresql";
    config = {
      DOMAIN = "https://vault.${d}";
      ROCKET_ADDRESS = "127.0.0.1"; ROCKET_PORT = 8222;
      DATABASE_URL = "postgresql:///vaultwarden?host=/run/postgresql";
      SIGNUPS_ALLOWED = false;
    };
    environmentFile = config.sops.secrets.vaultwarden-env.path;
  };
  systemd.services.vaultwarden = { after = [ "postgresql-setup.service" ]; requires = [ "postgresql-setup.service" ]; };   # the module does not order itself after its database

  services.syncthing = {
    enable = true;
    dataDir = "/srv/data/syncthing";
    openDefaultPorts = true;   # the sync port is public by decision (ADR 0008)
    guiAddress = "127.0.0.1:8384";   # the GUI is behind nginx, on the VPN address only (edge.nix)
    settings.gui.insecureSkipHostcheck = true;
  };

  # WebDAV for Seedvault: nginx with its DAV modules (ADR 0011), the user file a bcrypt file from sops
  services.nginx.additionalModules = [ pkgs.nginxModules.dav ];
  systemd.services.nginx.serviceConfig.ReadWritePaths = [ "/srv/data/webdav" ];

  services.smartd = lib.mkIf (!cfg.lab) {
    enable = true;
    autodetect = false;
    devices = map (device: { inherit device; }) [ cfg.disks.system cfg.disks.tank cfg.disks.backup16 cfg.disks.big2tb ];
  };

  virtualisation.oci-containers.containers = {
    immich-redis = {
      image = "docker.io/valkey/valkey@sha256:70739f85ad2ee01a726a965584a0f94895f01b0c60b3cc8b0aeef11eaa6888cf";   # 8-bookworm
      extraOptions = [ "--network=host" ];
    };
    immich-server = {
      image = "ghcr.io/immich-app/immich-server@sha256:d317916b28090c33eb36b308464ea391f8b7df1d850fcfea227a39ec879718c2";   # v3.2.4
      environment = dbEnv // { IMMICH_MACHINE_LEARNING_URL = "http://127.0.0.1:3003"; };
      volumes = [ "/srv/data/immich/upload:/data" "/run/postgresql:/run/postgresql" ];
      dependsOn = [ "immich-redis" ];
      extraOptions = [ "--network=host" ] ++ lib.optional (!cfg.lab) "--device=/dev/dri";
    };
  } // lib.optionalAttrs cfg.services.immichMachineLearning.enable {
    immich-machine-learning = {
      image = "ghcr.io/immich-app/immich-machine-learning@sha256:e16c2f166a8174901959fdf85e2e4c7bd1ebc4b37e0b6655de97c41408a260c4";   # v3.2.4
      volumes = [ "/srv/data/immich/model-cache:/cache" ];
      extraOptions = [ "--network=host" ] ++ lib.optional (!cfg.lab) "--device=/dev/dri";
    };
  } // lib.optionalAttrs cfg.services.jellyfin.enable {
    jellyfin = {
      image = "docker.io/jellyfin/jellyfin@sha256:78d3ea1207d1322471fcac39a614f004f2ccf7e878f95ab2977d752f07e4dd7e";   # 12.1
      volumes = [ "/srv/data/jellyfin/config:/config" "/srv/data/jellyfin/cache:/cache" "/mnt/backup16/media:/media:ro" ];
      extraOptions = [ "--network=host" ] ++ lib.optional (!cfg.lab) "--device=/dev/dri";
    };
  };
  systemd.services.podman-immich-server = { after = [ "postgresql.service" ]; requires = [ "postgresql.service" ]; };

  systemd.tmpfiles.rules = [
    "d /srv/data/immich 0755 root root -" "d /srv/data/immich/upload 0755 root root -" "d /srv/data/immich/model-cache 0755 root root -"
    "d /srv/data/jellyfin 0755 root root -" "d /srv/data/jellyfin/config 0755 root root -" "d /srv/data/jellyfin/cache 0755 root root -"
    "d /srv/data/webdav 0750 nginx nginx -" "d /srv/data/webdav/.tmp 0750 nginx nginx -"
  ];
}
