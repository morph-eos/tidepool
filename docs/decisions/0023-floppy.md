# 0023. Floppy: a private tracker for what is watched, read and played

- **Status:** accepted; built (`nixos/modules/floppy.nix`, **off by default**: `tidepool.services.floppy.enable`) and proven in the lab
- **Date:** 2026-11-08
- **Phase:** services, after the first deployment

## The question

I want one place, mine, that remembers what I watched, read and played, and what comes next: the films and series that a hosted tracker keeps today, the books that a hosted reading list keeps, and the games that nothing keeps. It must be private (no social side, no public profile), open source, reachable without the VPN like the other services, behind the same single sign-on, and it must be fed by what the media server already knows. It also keeps the listening statistics of the music played on the media server and gives a yearly recap, by mail, to each person.

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
- **Sign-in through Nextcloud** ([ADR 0020](0020-brand-identity.md)): `tidepool.sso.clients.floppy` registers the client, and the same declaration writes Floppy's side (django-allauth's OpenID Connect provider, with PKCE, discovered from the same document as Immich's). The sign-in page offers only that button. A first sign-in makes the account; **nobody signs up by a form**: the edge answers 404 on the sign-up address and slows the sign-in pages down (a request a second on average per address, a burst of 20; the webhook and the scrobble addresses carry a token and are not limited), and without the single sign-on registration is off altogether (an account is then made by hand: `podman exec -it floppy python manage.py createsuperuser`).
- **The brand's look.** The edge adds one stylesheet to Floppy's pages (the palette, the buttons' colours and the logo, from the same brand file as every other service; [ADR 0020](0020-brand-identity.md) and [the register of exceptions](../exceptions.md)), because its themes are per user. The TV session's start page has a tile for it.
- **Keys of the metadata providers.** Floppy ships shared default keys for the film, game and book databases; they work, with a quota shared among all installs. Each user can enter their own key in Floppy's settings (stored sealed by the secret above).
- **An account for everyone Nextcloud lists** (`tidepool.services.floppy.accounts`, on by default with the single sign-on; `nixos/floppy/ensure-accounts.py`). A timer asks Nextcloud for its enabled users every ten minutes and gives each one the Floppy account that is missing, with no password and the link to the sign-on identity, so the first sign-in lands in that account. The reason is practical: a new person is covered without anyone remembering to add them, and the recap and the media server's plugins have an account to work with before the person has opened the site. It never deletes an account, and a disabled user gets none.
- **The yearly recap by mail** (`tidepool.services.floppy.recap.enable`, off by default because it sends mail to people; `nixos/floppy/wrapped.py`). On 1 December (`recap.calendar`) a unit goes through every enabled Nextcloud user who has a Floppy account and an address in Nextcloud, and mails each their own recap through the alerts' relay. It is computed from that person's history alone, through Floppy's REST API on the loopback, with the Python standard library only; nothing is stored, and nobody's data is in anyone else's mail. Someone without an address, without an account or with nothing tracked in the year is skipped; if one mail fails the others still go and the unit ends failed, which the alerts report. There is no switch for a person to opt out yet. The recap borrows what the hosted ones do (one big number per card, ranked lists, a fixed calendar window, the year before as comparison, superlatives, a character derived from habits by plain rules) and covers music, films, series and anime, reading, games and podcasts. A preview needs only a token: `wrapped.py --url ... --token-file ... --year 2026 --out preview.html`.
- **The admin page**, the HTTPS probe, the version watch (the tag against the project's latest GitHub release) and the lab's checks know the service when it is on.

## How the media server feeds it (configured in Jellyfin, not in Nix)

Jellyfin's plugins keep their settings in Jellyfin's own configuration, which is backed up with `/srv/data`; they are not declared in the flake (the same limit as Jellyfin's libraries and users).

- **Films and episodes:** the official Webhook plugin posts to Floppy's webhook address with the template that Floppy's documentation gives; a film watched again inside its own running time is a duplicate and is ignored, after it a second entry.
- **Music:** a ListenBrainz scrobbler plugin for Jellyfin pointed at Floppy's ListenBrainz-compatible address with the user's token. The plugin is third-party and built for an older Jellyfin: if an upgrade breaks it, Jellyfin's Playback Reporting plugin keeps the same events and Floppy imports them.
- **A script writes those settings** (`nixos/floppy/jellyfin-link/`): `apply.sh --host SSH-NAME --url https://track.EXAMPLE.ORG --floppy-user NAME --jellyfin-user NAME` reads the person's token from Floppy's database on the server, writes the two plugins' files (the Webhook template is Floppy's own; ListenBrainz gets Floppy's address without the `/1/` the API adds itself) and restarts Jellyfin. Only the chosen Jellyfin user is sent, because a media server has other people on it. It refuses to overwrite settings someone made by hand (`--check` says what it would do). The person must have an account first, which the accounts timer takes care of.
- **Timed lyrics** are not part of this service: the media server reads a `.lrc` file beside a track; [two small scripts](../../nixos/jellyfin/lyrics/README.md) fetch synced lyrics from LRCLIB and make a transliterated TTML from one (the media mounts stay read-only for Jellyfin, so its own lyrics plugin cannot write them; the scripts run as a user who can write to the library).

## What the lab proved

The host `lab` runs Floppy: its migrations over the socket as root and the web processes as `tracker` (the smoke test reads both), the role refused every other database and every other user, the answer and the health page through the edge, the sign-up address refused. The host `lab-brand` also runs the sign-on: the button leads to Nextcloud, and a login there returns to Floppy with an account made (`lab/brand-check.sh`); two Nextcloud users who never signed in get an account and a link each from the accounts timer, and a second run makes nothing new; the recap's unit is built there and sends nothing until its date. The first start on an empty database runs every migration and takes minutes; the smoke test waits for it.

## What it does not do

- It does not search for new music to stream. No open-source server-side option exists; the choices (an external player, or a downloader that fills a separate library) are outside this record.
- It does not fetch lyrics or keep the music (Jellyfin does).
- It does not import the media server's history, and it does not import a hosted tracker's history by itself: the importers need that account's export or authorization, which only its owner has. The media server's old history is not worth importing either: the hosted tracker's export is the better source, and from the plugins on, new plays arrive by themselves.

## To revisit

- If Floppy stops being maintained, Yamtrack takes its place through the CSV.
- A newer image may let the listener bind the loopback; then this service has the second lock too.
- Whether the ListenBrainz plugin survives the next Jellyfin release (see above).

## Update (2026-11-08, names): title, button, and the lyrics' scripts

- **The title and the app's name are the brand's.** The edge's filter that carries the palette also rewrites the page's title and the installed app's name to the name of the service ("Tidepool Track", from the brand's name and its `track` label), in place of "Floppy" ([ADR 0020](0020-brand-identity.md), exception 9). The logo image is the brand's on every page.
- **The sign-in button is the brand's generic text** ("Sign in with SSO", the `signInLabel` field): it is the name of the OpenID Connect provider that Floppy shows as the button, and it is set from the same declaration as the client.
- **The scripts for timed lyrics are in the repository** ([nixos/jellyfin/lyrics/](../../nixos/jellyfin/lyrics/README.md)), as prototypes: they fill the sidecar `.lrc` files from LRCLIB and make a TTML file with a Latin transliteration track. They were run on a small made-up library; how a client shows the TTML was not tried.
