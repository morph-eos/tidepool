# 0023. Floppy: a private tracker for what is watched, read and played

- **Status:** accepted; built (`nixos/modules/floppy.nix`, **off by default**: `tidepool.services.floppy.enable`) and proven in the lab
- **Date:** 2026-11-08
- **Phase:** services, after the first deployment

## The question

I want one place, mine, that remembers what I watched, read and played, and what comes next: the films and series that a hosted tracker keeps today, the books that a hosted reading list keeps, and the games that nothing keeps. It must be private (no social side, no public profile), open source, reachable without the VPN like the other services, behind the same single sign-on, and it must be fed by what the media server already knows. It also keeps the listening statistics of the music played on the media server and gives a yearly recap.

## What was considered

| Option | Verdict |
|---|---|
| **Floppy** (a maintained fork of Yamtrack, AGPL, a container image published by the project) | **chosen**: films, series, anime, books, games and more in one library; a "what's next" view and a calendar; a yearly recap and statistics over a date range; importers for the common hosted trackers and for the Yamtrack CSV; receivers for the media server's webhook and for ListenBrainz-format scrobbles; sign-in through OpenID Connect; a REST API. It reads and writes the Yamtrack CSV, so leaving it is cheap. |
| Yamtrack (upstream) | the same family with fewer features (in the version tried it had no ListenBrainz receiver). Kept as the way back: the CSV goes both ways. |
| A self-hosted scrobble store (Koito) in front of it | an independent archive of listens, a second service with its own SQLite file. Not now: Floppy takes the scrobbles itself, and a store can be put in front later by changing one address. |
| Hosted trackers | the point of the change is to leave them. |

Floppy's community is much smaller than Immich's or Jellyfin's, and it releases weekly. I accept that for a service whose data can be exported at any time and whose failure loses nothing else: it is pinned by digest like the other containers and watched by the version watch ([ADR 0017](0017-version-watch-push-and-nas.md)).

## What was built

`tidepool.services.floppy.enable` (off by default, because it needs the secret `floppy-secret` and the single sign-on). The name is `track.<domain>`, public like the other services; the wildcard record and the wildcard certificate already cover it ([the names](../names.md)).

- **A pinned container under Podman**, like Immich and Jellyfin ([ADR 0011](0011-services.md)): no NixOS module exists. The tag says the version (the version watch reads it), the digest pins it, and the image's own health check is off for the reason Jellyfin's is (a transient unit that failed once at every boot); the site is watched by the HTTPS probe and the admin page.
- **PostgreSQL over the Unix socket, no password**, as for Immich: a role and a database `floppy`, owned by the role, closed to every other role. The container's start-up runs the migrations as root and then drops to the number given as `PUID`/`PGID`, which is the host's user `tracker` (a fixed number, 1003, like the TV session's): `pg_ident` maps both `root` and `tracker` to the role `floppy` and to nothing else, so a compromised Floppy reaches its database and no other. The database is covered by pgBackRest with the rest of the cluster and can be dumped into both Borg repositories (`tidepool.backup.databaseDumps`).
- **Its own Valkey** on the loopback (port 6380), not Immich's: Floppy sets memory limits on the Redis it is given, and a second instance is small. The queue lives in an append-only file under `/srv/data/floppy/redis` that the file backups leave out (a copy of a running queue is worth nothing); the media metadata it caches is rebuilt on demand.
- **The listener.** The image runs its own nginx in front of its application server and takes only a port, not an address, so under the host network it listens on every interface. The firewall opens no port for it, nginx at the edge is the only way in, and the TV session's rule keeps that user off the loopback ports (ADR 0022). That is one lock where the other services have two, and the reason is in this paragraph.
- **Sign-in through Nextcloud** ([ADR 0020](0020-brand-identity.md)): `tidepool.sso.clients.floppy` registers the client, and the same declaration writes Floppy's side (django-allauth's OpenID Connect provider, with PKCE, discovered from the same document as Immich's). The sign-in page offers only that button. A first sign-in makes the account; **nobody signs up by a form**: the edge answers 404 on the sign-up address, and without the single sign-on registration is off altogether (an account is then made by hand: `podman exec -it floppy python manage.py createsuperuser`).
- **Keys of the metadata providers.** Floppy ships shared default keys for the film, game and book databases; they work, with a quota shared among all installs. Each user can enter their own key in Floppy's settings (stored sealed by the secret above).
- **The admin page**, the HTTPS probe, the version watch (the tag against the project's latest GitHub release) and the lab's checks know the service when it is on.

## How the media server feeds it (configured in Jellyfin, not in Nix)

Jellyfin's plugins keep their settings in Jellyfin's own configuration, which is backed up with `/srv/data`; they are not declared in the flake (the same limit as Jellyfin's libraries and users).

- **Films and episodes:** the official Webhook plugin posts to Floppy's webhook address with the template that Floppy's documentation gives; a film watched again inside its own running time is a duplicate and is ignored, after it a second entry.
- **Music:** a ListenBrainz scrobbler plugin for Jellyfin pointed at Floppy's ListenBrainz-compatible address with the user's token. The plugin is third-party and built for an older Jellyfin: if an upgrade breaks it, Jellyfin's Playback Reporting plugin keeps the same events and Floppy imports them.
- **Timed lyrics** are not part of this service: the media server reads a `.lrc` file beside a track; a script that fetches synced lyrics writes them (the media mounts stay read-only for Jellyfin, so its own lyrics plugin cannot).

## What the lab proved

The host `lab` runs Floppy: its migrations over the socket as root and the web processes as `tracker` (the smoke test reads both), the role refused every other database and every other user, the answer and the health page through the edge, the sign-up address refused. The host `lab-brand` also runs the sign-on: the button leads to Nextcloud, and a login there returns to Floppy with an account made (`lab/brand-check.sh`). The first start on an empty database runs every migration and takes minutes; the smoke test waits for it.

## What it does not do

- It does not search for new music to stream. No open-source server-side option exists; the choices (an external player, or a downloader that fills a separate library) are outside this record.
- It does not fetch lyrics, keep the music (Jellyfin does), or send the yearly recap by mail (Floppy has a recap page; a mailed copy would read its API and is a script of its own).
- It does not import a hosted tracker's history by itself: the importers need that account's export or authorization, which only its owner has.

## To revisit

- If Floppy stops being maintained, Yamtrack takes its place through the CSV.
- A newer image may let the listener bind the loopback; then this service has the second lock too.
- Whether the ListenBrainz plugin survives the next Jellyfin release (see above).
