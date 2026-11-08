# Floppy (ADR 0023): the private tracker for what is watched, read and played, at track.<domain>. A pinned container under Podman, like Immich and Jellyfin, because no NixOS module exists for it.
# Its database is in PostgreSQL over the Unix socket, no password (database.nix), its queue is a Valkey of its own, its files are under /srv/data/floppy. Off by default (tidepool.services.floppy.enable).
# People log in through the single sign-on (sso.nix registers the client and writes Floppy's side of it); without it nobody can sign up, an account is made by hand (docs/decisions/0023-floppy.md).
{ config, lib, ... }:
let
  cfg = config.tidepool;
  d = cfg.domain;
  fl = cfg.services.floppy;
  # Floppy's web and worker processes run as this user inside the container (the image calls it `abc` and numbers it from PUID/PGID). The same number on the machine is the user `tracker` (by purpose; NixOS already has a group `floppy`, the old disk drives'),
  # which is what PostgreSQL sees on the Unix socket (peer authentication), so the database role needs no password. The image's start-up runs the migrations as root first: database.nix maps root to the same role.
  uid = 1003;
  port = 8100;        # the image's own nginx; the container shares the machine's network, and the firewall does not open this port (nginx at the edge is the only way in)
  redisPort = 6380;   # Immich's Valkey keeps 6379: Floppy would set limits on a Redis it shares, so it has its own
  acme = if cfg.lab then { enableACME = true; } else { useACMEHost = d; };
in
{
  config = lib.mkIf fl.enable {
    users.users.tracker = { isSystemUser = true; group = "tracker"; inherit uid; description = "Floppy's identity (the container's processes, its database role)"; };
    users.groups.tracker.gid = uid;

    sops.secrets.floppy-secret = { };   # Floppy signs sessions and CSRF tokens with it and derives the key that seals the integrations' credentials: keep it, a change makes those unreadable
    sops.templates."floppy.env" = { content = "SECRET=${config.sops.placeholder.floppy-secret}\n"; restartUnits = [ "podman-floppy.service" ]; };

    virtualisation.oci-containers.containers = {
      floppy-redis = {
        image = config.virtualisation.oci-containers.containers.immich-redis.image;   # the one Valkey pin of the repository
        # the containers share the machine's network: bound to the loopback only (the firewall is the second lock); append-only file so the queue survives a restart, a memory ceiling so a full queue is an eviction and not an out-of-memory kill (the upstream's own advice)
        cmd = [ "valkey-server" "--port" (toString redisPort) "--bind" "127.0.0.1" "-::1" "--appendonly" "yes" "--save" "" "--maxmemory" "256mb" "--maxmemory-policy" "volatile-lru" ];
        volumes = [ "/srv/data/floppy/redis:/data" ];
        extraOptions = [ "--network=host" ];
      };
      floppy = {
        image = "ghcr.io/dannyvfilms/floppy:26.10.29@sha256:5e88307d4af68ee397f0233670b4f35f50d6ce5d12c34fde6b9ecab74ac4836e";
        environment = {
          FLOPPY_PORT = toString port;
          PUID = toString uid; PGID = toString uid;
          TZ = if config.time.timeZone == null then "UTC" else config.time.timeZone;
          DB_HOST = "/run/postgresql"; DB_PORT = "5432"; DB_NAME = "floppy"; DB_USER = "floppy"; DB_PASSWORD = "unused-peer-auth";   # a Unix socket: the host is a directory, the port only names the socket file, the settings insist on a password and the peer authentication ignores it
          REDIS_URL = "redis://127.0.0.1:${toString redisPort}";
          # the edge terminates TLS and passes the name through: the name Floppy answers to and trusts, and the scheme it builds its own links with
          ALLOWED_HOSTS = "track.${d}"; URLS = "https://track.${d}";
          USE_X_FORWARDED_PROTO = "True"; SESSION_COOKIE_SECURE = "True"; CSRF_COOKIE_SECURE = "True";
          ADMIN_ENABLED = "False"; DEMO_ACCOUNT_ENABLED = "False"; DEBUG = "False";
          # with the single sign-on nobody signs up by a form (only the sign-in through Nextcloud creates an account, and the edge refuses the form); without it nobody signs up at all
          REGISTRATION = if cfg.sso.enable then "True" else "False";
          SOCIALACCOUNT_ONLY = if cfg.sso.enable then "True" else "False";
        };
        environmentFiles = [ config.sops.templates."floppy.env".path ];
        volumes = [ "/srv/data/floppy/db:/floppy/db" "/srv/data/floppy/backups:/floppy/backups" "/run/postgresql:/run/postgresql" ];
        dependsOn = [ "floppy-redis" ];
        # no health check of the image's own: podman runs it once a second after the start, before the site listens, and that transient unit stays failed ("degraded" after every boot, as Jellyfin did); the HTTPS probe watches the site
        extraOptions = [ "--network=host" "--no-healthcheck" "--stop-timeout=150" ];   # upstream asks for 150 s on stop: a running task gets 60 s to finish and the web server 30
      };
    };
    systemd.services.podman-floppy = { after = [ "postgresql.service" "postgresql-setup.service" ]; requires = [ "postgresql.service" "postgresql-setup.service" ]; serviceConfig.TimeoutStopSec = lib.mkForce 180; };   # the role and the database are made by postgresql-setup

    systemd.tmpfiles.rules = [
      # the tracker's files are for its container, which starts as root and hands them to the user above: closed to every other local user, the TV session's included (ADR 0022)
      "d /srv/data/floppy 0700 root root -" "d /srv/data/floppy/db 0700 root root -" "d /srv/data/floppy/backups 0700 root root -" "d /srv/data/floppy/redis 0700 root root -"
    ];

    services.nginx.virtualHosts."track.${d}" = acme // {
      forceSSL = true;
      locations = {
        "/" = { proxyPass = "http://127.0.0.1:${toString port}"; proxyWebsockets = true; };
      } // lib.optionalAttrs cfg.sso.enable {
        # the sign-up form would let anyone with the address make an account; the single sign-on is the way in
        "= /accounts/signup/".return = "404";
      };
    };
  };
}
