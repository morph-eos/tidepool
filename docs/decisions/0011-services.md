# 0011. How each service runs: its NixOS module or a declared container

- **Status:** accepted (2026-10-01): native Nextcloud, Vaultwarden, Syncthing, smartd and PostgreSQL; Jellyfin 12.1 and Immich as pinned containers; WebDAV through nginx; Nextcloud as the single sign-on provider; icloudpd and Plex dropped
- **Date:** 2026-10-01
- **Phase:** 4, Services
- **Update 2026-10-03:** the owner considered moving Nextcloud, Vaultwarden and WebDAV to containers and **kept the modules** ([ADR 0017 section 1](0017-version-watch-push-and-nas.md)): the configuration of Nextcloud (OIDC and the rest) is far simpler declared in Nix; staleness is watched by the weekend version watch instead.

## Context

v0 runs every service as a Docker container from one Compose file, with the images pinned by digest: **Immich** (server, machine learning in its OpenVINO build, a Valkey cache, a PostgreSQL 14 image), **Jellyfin** (with hardware transcoding), **Plex** and a tool that syncs watch state (both off, and **dropped**), **Vaultwarden**, **WebDAV** (for the phones), **Syncthing**, **icloudpd** (iCloud photos into Immich, on a profile), **Nextcloud** (with MariaDB and Redis), nginx and certbot (replaced by [ADR 0008](0008-edge.md)), and a **`smartcheck`** container that watches the disks.
Several integrations are done by scripts: Nextcloud as an OpenID Connect provider for Jellyfin and Vaultwarden (`setup_nextcloud_oidc.sh`), Jellyfin's SSO button (`setup_jellyfin_sso_button.sh`). The databases move to PostgreSQL ([ADR 0004](0004-backup.md)).

The question of this ADR is, for each service: **its maintained NixOS module, or a container declared in the flake and pinned by digest** ([P1](../principles.md): both are accepted; the module is preferred when it fits).

## Requirements

- **Must:** the service runs the **same major version as v0 or a newer one** (v0's data must open, and no service may run an end-of-life or flagged-insecure version); it uses PostgreSQL where it can ([ADR 0004](0004-backup.md)); it is reachable through the proxy of [ADR 0008](0008-edge.md) with the real client IP; its secrets are sops-nix files ([ADR 0003](0003-secrets.md)); its data sit on the disks of [ADR 0005](0005-storage-layout-and-filesystem.md); an update is a change of a version or a digest plus the same checks.
- **Should:** isolation (a sandbox for a native service, a container for the others); few lines of our own; a restore that is part of the drill.
- **Won't:** a service that needs a script to configure it; Plex and its helper; certbot; the `smartcheck` container (a maintained module does that job).

## What each service has (searched and measured on 2026-10-01)

Versions: what v0 runs, what the channel (nixos-26.05) packages, and the **latest upstream release**.

| Service | v0 | NixOS module | In this channel | Latest upstream | Fit |
|---|---|---|---|---|---|
| Immich | 3.x container | `services.immich` | **2.7.5, flagged insecure** (no more 2.x updates, CVE-2026-59258) | 3.2.4 | **module unusable** |
| **Jellyfin** | **12.1** container | `services.jellyfin` | **10.11.11** | **12.1** | **module two major versions behind v0** |
| Nextcloud | 33 container | `services.nextcloud` | 33.0.9 and 34.0.4 | 35.0.1 | the module has v0's major |
| Vaultwarden | 1.37.1 | `services.vaultwarden` | 1.37.3 | 1.37.3 | module is current |
| Syncthing | 2.0.14 | `services.syncthing` | 2.1.3 | 2.1.5 | module is newer than v0 |
| WebDAV | `bytemark/webdav` (Apache) | `services.webdav` (a different server, hacdias's) | present | | module works; see below |
| icloudpd | 1.32.2 container | **none** (the package exists: 1.32.2) | 1.32.2 | 1.32.3 | no module |
| Disk health | `smartcheck` container | `services.smartd` | smartmontools 7.5 | | module replaces the container |
| Database, cache | containers | `services.postgresql`, `services.redis.servers` | PostgreSQL 17 | | native |

## Results

**Jellyfin: the decisive test.** A Jellyfin **12.1** container (`jellyfin/jellyfin:12.1`, 2.5 GB) started on an empty directory and wrote its database; the **native module's 10.11** was then started on a copy of that data (`exp/services-native`). It **failed to start**: `SQLite Error 1: 'no such column: b.ExtraIds'`, then `Main: Error while starting server`. **A database written by 12.1 cannot be opened by 10.11**: using the module would mean starting from an empty library, losing v0's users, watch history and metadata.

**The other services through their modules**, in the lab VM, behind nginx with certificates from the test CA, with PostgreSQL 17 over its Unix socket (`lab/services-native-bakeoff.sh`):

| Check | Result |
|---|---|
| Nextcloud 33.0.9 | installed, **database `pgsql`**, **Redis** cache, through the proxy over HTTPS |
| Vaultwarden | `/alive` answers, **PostgreSQL** backend |
| Syncthing | answers behind the proxy **after one setting** (it refuses a proxied `Host` header with 403 otherwise: `insecureSkipHostcheck`, acceptable because the GUI is VPN-only); the sync port 22000 listens |
| WebDAV | `PROPFIND` with the right password: 207; a wrong one: 401 |
| smartd | the module **refuses a configuration with no devices** (a useful check); not run (the lab VM has no SMART disk) |
| Idle memory, all of them together | about **150 MiB** (PostgreSQL 67, PHP-FPM 39, Syncthing 20, Vaultwarden 9, nginx 8, Redis 5, WebDAV 4) |
| **Our own configuration** | **48 lines** for PostgreSQL, Nextcloud, Vaultwarden, Syncthing, WebDAV, smartd and Jellyfin, plus 29 for the proxy |

**systemd isolation of each native unit** (`systemd-analyze security`, lower is better):

| Unit | Exposure |
|---|---|
| Vaultwarden | 1.2 OK |
| PostgreSQL | 1.3 OK |
| nginx | 1.6 OK |
| Syncthing | 5.1 MEDIUM |
| **Nextcloud (PHP-FPM)** | **7.9 EXPOSED** |
| **WebDAV** | **9.2 UNSAFE** (the module applies almost no sandbox) |

What running them showed:
- **Ordering is not always done for you**: Nextcloud's setup raced the database when I created the role myself (use `services.nextcloud.database.createLocally = true`, which creates it and orders after it), and **Vaultwarden needed `after` and `requires` on `postgresql-setup.service`** (two lines) because its module does not order itself after the database.
- **A failed first installation of Nextcloud is not recoverable by restarting**: it left a half-made `config.php`, and the next run tried to *upgrade* an instance that was never installed; the state directory and the database had to be emptied by hand. Worth knowing for the first deployment, and a reason to test the setup in the lab first.
- **A module's `ensureUsers` and the service's own setup do not know each other**; the module option that wraps both is the right one.
- **Nextcloud's apps can be declared**: `oidc`, `oidc_login`, `user_oidc` and `user_saml` are available as Nix packages (`services.nextcloud.extraApps`), so installing them is not an imperative step in the app store.
- **NixOS has modules for several identity providers**: `services.kanidm`, `services.authelia`, `services.keycloak`, `services.pocket-id`, `services.zitadel`, `services.dex`. Which one, if any, replaces v0's "Nextcloud as the provider plus scripts" is a separate design question, below.

**WebDAV for Seedvault, two ways** (`lab/services-extra-bakeoff.sh`): a backup-app-like sequence (MKCOL, PUT of 5 MB, PROPFIND, MOVE, GET, DELETE, a **2 GB PUT**, a wrong password) against **the `webdav` module with its unit hardened** and against **nginx with its WebDAV modules** (`services.nginx.additionalModules`).

| | `webdav` module, hardened | nginx with the DAV modules |
|---|---|---|
| The whole sequence | **passes** (2 GB in 10 s) | **passes** (2 GB in 5 s) |
| systemd exposure | **9.2 UNSAFE as shipped, 2.2 OK** after about 12 lines of systemd options of our own (an override of the module's unit) | **1.6 OK**, the unit nginx already has |
| Extra service and user | one more | none |
| Cost | the 12 lines; the module's own settings for users | nginx is rebuilt with the module (a build, no hash to refresh); the user file is a bcrypt file from a sops secret |

Seedvault itself talks to a WebDAV server through **DAVx5's WebDAV mount** or **Nextcloud's own app** ([the discussion](https://github.com/seedvault-app/seedvault/discussions/494)); a recent DAVx5 release stopped being recognised by Seedvault on GrapheneOS ([issue](https://github.com/GrapheneOS/os-issue-tracker/issues/7810)), a client-side matter that does not depend on the server. **Neither server was tried with a real phone.**

**Nextcloud as the OpenID provider** (`exp/services-native`):
- **The `oidc` app (2.3.1) is declared** (`extraApps`) and enabled: no app-store step.
- **A client is created with one command**, `occ oidc:create`, **with the client identifier and secret we choose** (the identifier must be 32 to 64 printable characters), so they can be sops secrets and the command can be run again after `oidc:remove`: it is **idempotent in effect**. The clients are **rows in the database**, so a restore brings them back; **a rebuild from nothing needs the commands again**.
- **Simpler than v0**: v0 inserted the redirect addresses with SQL into MariaDB (`setup_nextcloud_oidc.sh`) because `oidc:create` cannot add one afterwards, and each service had **two** addresses (two domains). With **one domain** each client has **one** address, so the SQL goes away.
- **The discovery document** is at `/.well-known/openid-configuration` after **a 301 redirect**, and also directly at `/index.php/apps/oidc/openid-configuration`; its `issuer` is `https://<cloud name>`. A strict client (Vaultwarden checks the issuer against its authority) may not follow the redirect: **the well-known address should answer directly** (a rewrite in the virtual host), **to be settled when the integration is built**.
- **Not tested:** a real login through Nextcloud into Vaultwarden, Jellyfin or Immich, and Jellyfin's SSO plugin.

**Not tested:** Jellyfin's **hardware transcoding** (the lab has no GPU; the real-server check G2 is pending), Immich's machine learning on the owner's GPU, a **restore** of any of these (the drill of phase 7), the **icloudpd** service, a real smartd on the disks, the **SSO** integrations, and the owner's phone apps against the WebDAV server.

## Criteria, in this order

1. **P1 and data:** a maintained module whose version can open v0's data and is not flagged insecure; otherwise a container pinned by digest.
2. **Isolation and hardening** (measured).
3. **Lines of our own and ordering pitfalls.**
4. **Update path:** what a new upstream version costs (the channel's cadence against the digest bump).
5. **Fit with the backups and the disks.**

## Decision (2026-10-01)

The owner's answers: **WebDAV is for Seedvault** (GrapheneOS); the **GPU is an Intel one**; **icloudpd is dropped**; **Nextcloud stays the single sign-on provider** for the services; **for now only the services that exist today move over**, the new ones come later.

**Through their NixOS modules:** PostgreSQL 17 and its databases ([ADR 0006](0006-postgresql-version-and-immich.md)); **Nextcloud 33** (`database.createLocally`, Redis, the `oidc` app declared); **Vaultwarden** on PostgreSQL (with the ordering after the database written out); **Syncthing** (sync port public, GUI VPN-only); **`smartd` in place of the `smartcheck` container**; nginx.

**As containers, declared and pinned by digest** (the module cannot serve v0's data or is flagged insecure):
- **Jellyfin 12.1**: the module's 10.11 cannot open a 12.1 database (tested). With the **Intel GPU**, transcoding goes through the render device (`/dev/dri`) with VA-API; the check **G2** on the real server confirms it.
- **Immich** (server and machine learning), with the native PostgreSQL 17 of ADR 0006. **The machine learning keeps v0's OpenVINO build**, which suits an Intel GPU (it needs the render device and the Intel compute runtime on the host); confirmed on the real server.

**WebDAV for Seedvault: nginx with its DAV modules** (recommended): it passed the whole sequence, adds **no service and no user**, and its unit scores 1.6; **the fallback is the `webdav` module with its unit hardened** (2.2, about 12 lines of ours). Neither was tried with a phone: **the first real Seedvault backup is the test.**

**Single sign-on: Nextcloud as the provider**, with its `oidc` app declared in the flake. Three clients (**Immich, Jellyfin, Vaultwarden**, as in v0), each registered by `occ oidc:create` with an identifier and a secret taken from sops. **The registration is a small declared step that runs after Nextcloud's setup** (three commands, ten lines or so): it is **glue under P1** (an application that cannot declare its clients), so it goes **in [the register](../exceptions.md)** when it is written, with a check at every upgrade (`oidc:list` matches what the flake says). Jellyfin's SSO plugin and the button of v0 are part of the Jellyfin work.

**Dropped:** Plex and its helper, **icloudpd**, certbot, the proxy container, the `smartcheck` container.

**Updates:** the native services follow the channel (`flake.lock`), the containers follow a digest bump that is reviewed; **both are a version change plus the same checks**, and a **Nextcloud major version is upgraded one step at a time** (the module enforces it).

## Questions answered, and what remains

1. ~~WebDAV~~: Seedvault; nginx recommended. 2. ~~GPU~~: Intel. 3. ~~icloudpd~~: dropped. 4. ~~Single sign-on~~: Nextcloud. 5. ~~New services~~: later.
**Remaining:** the **wording of the first real checks** (a Seedvault backup through nginx, Jellyfin's transcode on the GPU, Immich's machine learning on it, a login through Nextcloud into each service) belongs to the deployment and to the restore drill.
