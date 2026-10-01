# 0011. How each service runs: its NixOS module or a declared container

- **Status:** proposed (lab results in; recommendation below; waiting for the owner's answers on a few inputs)
- **Date:** 2026-10-01
- **Phase:** 4, Services

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

**Not tested:** Jellyfin's **hardware transcoding** (the lab has no GPU; the real-server check G2 is pending), Immich's machine learning on the owner's GPU, a **restore** of any of these (the drill of phase 7), the **icloudpd** service, a real smartd on the disks, the **SSO** integrations, and the owner's phone apps against the WebDAV server.

## Criteria, in this order

1. **P1 and data:** a maintained module whose version can open v0's data and is not flagged insecure; otherwise a container pinned by digest.
2. **Isolation and hardening** (measured).
3. **Lines of our own and ordering pitfalls.**
4. **Update path:** what a new upstream version costs (the channel's cadence against the digest bump).
5. **Fit with the backups and the disks.**

## Decision

_Recommended, pending the owner's answers below._

**Through their NixOS modules:** PostgreSQL 17 and its databases ([ADR 0006](0006-postgresql-version-and-immich.md)), **Nextcloud 33** (with `database.createLocally`, Redis, and the OpenID apps declared as `extraApps`), **Vaultwarden** on PostgreSQL, **Syncthing**, **`smartd` in place of the `smartcheck` container**, nginx.

**As containers, declared and pinned by digest** (the module cannot serve v0's data or is flagged insecure):
- **Jellyfin 12.1** (the module's 10.11 cannot open a 12.1 database): the container with the GPU device for transcoding and the media as read-only volumes;
- **Immich**, with the native PostgreSQL 17 of ADR 0006 (the module is flagged insecure);
- **icloudpd** (no module), only if the owner still wants the iCloud sync.

**WebDAV: an open question for the owner** (below): the module works but has the weakest isolation of all (9.2), and Nextcloud already serves WebDAV (`/remote.php/dav`); if the phone apps can use Nextcloud's, **the separate server is dropped**.

**Dropped:** Plex and its helper, certbot, the proxy container, the `smartcheck` container.

**Updates:** the native services follow the channel (`flake.lock`), the containers follow a digest bump that is reviewed; **both are a version change plus the same checks**, and a **Nextcloud major version is upgraded one step at a time** (the module enforces it).

## Questions for the owner

1. **Which application do your phones use for WebDAV, and for what?** (If it can use Nextcloud's own WebDAV, the separate server goes away.)
2. **What GPU does the server have** (AMD, NVIDIA or Intel)? The type, not the model. It decides Jellyfin's transcoding setup and the build of Immich's machine learning (v0 uses the OpenVINO build, which is Intel's; an AMD card would use the CPU or a heavier ROCm build).
3. **Do you still want icloudpd?** (It is off in v0, on a profile.)
4. **What single sign-on do you want?** v0: Nextcloud as the provider, Jellyfin through a plugin with a button injected by a script, Vaultwarden through the same. The options are to **keep Nextcloud as the provider** (its OpenID app, declared in the flake; the clients still have to be registered in it by commands) or **a dedicated provider** from the list above (a separate service, with its own clients declared). This is its own decision; say whether you want it in this phase.
5. **Which new services** do you want to add (the replacement for Trakt, and others)? Each one gets the same comparison.
