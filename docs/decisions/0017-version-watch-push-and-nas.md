# 0017. The version watch, push notifications without the VPN, and the NAS

- **Status:** accepted as built, measured in the lab and not yet on real hardware
- **Date:** 2026-10-03
- **Phase:** 8, Updates and automation (follow-up of [ADR 0016](0016-updates-deploys-and-checks.md))

## Context

After [ADR 0016](0016-updates-deploys-and-checks.md) five things needed settling:

1. Should Nextcloud, Vaultwarden and WebDAV run in containers instead of NixOS modules? It was asked as a way to end the "module goes stale" problem.
2. A weekly alert that says, every weekend, when a new release exists upstream of any application and the module (or the container) has not followed it for at least a week: security patches and majors alike, modules and containers. If it cannot be done cleanly it may become a third exception ([exceptions.md](../exceptions.md)).
3. Push notifications without the VPN: the phone mainly runs a commercial VPN, and the server must not become the VPN for everything.
4. The NAS into the flake, and a measurement of everything about the VPN and push.
5. The public repository will become public once everything is on the server and the old scripts' security problems are fixed ([ADR 0003](0003-secrets.md)).

## 1. Modules or containers for Nextcloud, Vaultwarden and WebDAV

Considered before: [ADR 0011](0011-services.md) (modules where the module is current) and [ADR 0016](0016-updates-deploys-and-checks.md) (the exit from a module to the official container was tried: it works on the same data and database).

| | Module (kept) | Official container |
|---|---|---|
| Version lag | nixpkgs lag, measured median 1.8 days for Nextcloud and 0.7 for Vaultwarden | none by design, but the digest only moves when someone moves it |
| Nextcloud's configuration, the OIDC app, settings | declared in Nix (`extraApps`, `settings`): one file, reviewable | rebuilt by hand around the image: mounted files, an installed app, `occ` commands |
| Cron, PHP, caching, nginx integration | the module does them | a second container for cron, a PHP image choice (apache or fpm), the proxy by hand |
| WebDAV | not a service: it is nginx's own `dav` module (a few lines in the vhost) | would add a server where there is none |
| The "stale" signal | needed: section 2 | needed too (a pin that nobody moves is the same problem) |

I keep the modules; the containers already in the flake (Immich, Jellyfin, Valkey) stay as they are. A container would not have removed the need for a signal: it would have moved it from "nixpkgs is late" to "nobody bumped the pin". The escape hatch stays documented and tested.

A correction to ADR 0016: the stable branch carries Nextcloud 33.0.9, 34.0.4 and 35.0.0, not two majors. The module still refuses to skip a major, so 33 to 35 is two steps.

## 2. The version watch

The requirement: every weekend, check every application; if upstream has had a newer release for at least a week and the running system does not have it, send one mail. Majors count. Containers count.

### Options considered

| Option | Result |
|---|---|
| A. Repology (compares each repository with the newest upstream) | rejected. It files Nextcloud as `nextcloud-unclassified` with one entry per major, all `outdated` against the newest; Jellyfin 10.11 on the stable branch is `outdated` against 12.1; PostgreSQL 17 is `legacy`. It cannot tell a missing patch from a newer major, and Repology has its own lag |
| B. GitHub's "latest release" for everything | used for the apps with one line (Vaultwarden, Syncthing, Immich, Jellyfin, ntfy, Borg, pgBackRest, Incus). Not enough alone: it gives the newest release of the project, not of the line that runs, and json_exporter's JSONPath has no regular expression to pick a line from the release list |
| C. endoflife.date (the newest release of each line, with its date and whether the line is end of life) | used where it has the product: Nextcloud, PostgreSQL, nginx, Linux, OpenZFS, Podman, Samba. It lacks Vaultwarden, Syncthing, Immich, Jellyfin, Incus, ntfy and Borg (hence B). It also gives the end of life of the running line for free |
| D. A script (a timer that compares and mails) | not built: it would be exception 3, and C and B plus the rules below do it with zero scripts |
| E. Renovate (pull requests for pins) | complementary, not a substitute: it moves pins, it does not tell that a module is behind |

### How it works (all declared in Nix; no script)

- Deployed versions are written by `modules/versions.nix` into a text file read by the node exporter: they come from the packages and image tags of the system generation (`config.services.nextcloud.package.version`, the kernel's version, the tag of each container pin). So the watch compares what is really in the running generation, not what a service says about itself. For this to work the container pins are `repo:tag@sha256:...` (the tag is the version, the digest is the pin; a Renovate update moves both).
- Upstream versions are read once an hour by the NixOS module of json_exporter (9 MiB) from endoflife.date and from GitHub (a handful of requests an hour against GitHub's 60 without a login).
- The rules (`modules/versions/rules.yml`): the newest stable release of the line that runs is `tidepool:upstream_mine` (GitHub's latest release excludes pre-releases, checked on Syncthing, whose list starts with a release candidate; or endoflife.date's newest release of the running line). Recording rules say 1 or 0 every five minutes: actionable (upstream is ahead and nixpkgs already has that version, or the app does not come from nixpkgs: a lock bump or a new pin fixes it), waiting (upstream is ahead and nixpkgs does not have it yet: nothing to bump), major behind (a newer line exists) and line end of life.
- Two tiers of alerts, only on Saturday and Sunday from 07:00 UTC, each needing its whole window of samples. Weekly: `UpstreamReleaseNotDeployed` (actionable for 3 days). Monthly, the first weekend of the month only: `NixpkgsBehindUpstream` (waiting for 14 days), `UpstreamMajorNotAdopted`, `RunningLineEndOfLife`. `VersionWatchBlind` warns if a source cannot be read for a day, since silence would otherwise look like "all current". What nixpkgs has comes from Repology (the version of the stable branch).
- One mail per tier: the `weekly` and `monthly` alerts are grouped into a single mail each (`[FIRING:3] weekly (...)`), repeated only after 47 hours, and nothing is sent on "resolved".
- Covered: Nextcloud, PostgreSQL, nginx, Vaultwarden, Syncthing, Borg, pgBackRest, Immich, Jellyfin, the kernel, OpenZFS, Podman, Incus, Samba, ntfy. Not covered: Nextcloud's own apps, Valkey (its tag is a major line and it is Immich's private cache), the base images' operating-system packages, and the CVEs themselves (the watch says a release exists, not that it fixes a vulnerability).

### Measured

- Unit test of the rules (`modules/versions/rules.test.yml`, `promtool test rules`): 39 days of synthetic series and 18 checks. It is a flake check (`versions-rules`), so it runs on every `nix flake check`, and it fails when a rule is broken (tried twice: removing the "full window" condition, and widening the monthly gate).
- A flaky test, found and fixed: one run in fifteen failed. Prometheus 3 leaves the sample of exactly five minutes ago out of an instant lookup, so an alert that reads a recorded value can see nothing at the moment the recording is a few milliseconds late. The one rule that read an instant value now reads `last_over_time(...[15m])`: 0 failures in 40 runs afterwards. In production the same race would have dropped one alert evaluation in a while, harmless for a weekly alert, but a flaky test is a bug.
- End to end in the lab host against the real APIs (with a lock a few days old): the node exporter serves the deployed versions, json_exporter answers for all targets, the rules load. The watch found four real laggards on the stable branch (Syncthing, Borg, pgBackRest and Samba, each one or two patch releases behind) and that Podman's 5.8 line is end of life upstream while 26.05 ships it. Nextcloud, PostgreSQL, nginx, Vaultwarden, Immich and the kernel were current. Majors available: Nextcloud (34, 35) and PostgreSQL (18).
- The weekly mail: three alerts posted together gave one mail after the 5-minute group wait, and no mail when they expired.
- Cost: json_exporter 9 MiB; 376 more series in Prometheus (mostly endoflife.date's lists of old lines).

### What it does not give

- The first mail can come late. The window is "behind for three days since the watch first saw it", and the mail goes on the next weekend: a release on a Friday waits about 8.3 days, one on a Wednesday about 3.3. A 7-day window would have been 12.3 days at worst.
- Major reminders repeat every weekend for as long as a major is not adopted. That is what was asked; a deliberate hold (PostgreSQL 17 while Immich says so) will be a standing line. A "held major" setting can be added if it becomes noise.
- Distribution-maintained packages such as Podman 5.8 may be patched by nixpkgs although upstream ended the line; the alert will say "end of life" regardless. Drop the app from the list if it is noise.
- It watches two external services (endoflife.date, GitHub); if either disappears the watch goes blind and says so after a day.
- Exceptions: none. The register still has two entries.

### Is it the newest stable, and will it be spam?

The newest stable, yes, with two limits. Pre-releases are excluded at the source, and the check follows the line that runs: for Nextcloud, PostgreSQL, nginx, the kernel, ZFS, Podman and Samba it asks for the newest release of that line and, separately, whether a newer line exists. It does not follow LTS against feature releases (Incus runs the 7.0 LTS while GitHub's latest is the 7.5 feature line, so Incus is not watched), and it does not read security advisories.

The first version would have been spam. With the lab data it would have mailed about seven lines every weekend, and none of the first four could be fixed by me, because nixpkgs itself was behind. So the mail has two tiers:

| Tier | When | What |
|---|---|---|
| Weekly | every weekend | upstream has a newer stable release for 3 days and nixpkgs has it already (or the app is a container pin): something I can do |
| Monthly | the first weekend of the month | nixpkgs behind upstream for 14 days; a newer major exists; the running line is end of life |

An item moves from monthly to weekly the moment nixpkgs gets the version: the mail then says "bump the lock", which is the action. The unit test covers an app waiting for nixpkgs, one that nixpkgs then catches up on, one stalled only 4 days, an override (deployed equals upstream while nixpkgs is older: silent), and the weekend, first-weekend and 07:00 gates. What remains noisy: the monthly mail keeps naming the majors until they are adopted, and Podman's end of life until 26.11.

## 3. Push notifications without the VPN

Android and iOS run one VPN at a time ([Timus support](https://support.timusnetworks.com/hc/en-us/articles/42332497622291-Why-Running-Two-VPNs-on-the-Same-Device-Can-Be-Problematic)): with another VPN on, the server's WireGuard would be off, so a VPN-only ntfy would receive nothing. This was not tried on a phone; it is the platform's documented behaviour. The prototype of ADR 0016 (ntfy on the WireGuard address) therefore does not meet the requirement.

| Option | Result |
|---|---|
| A. ntfy on the VPN address only | works in the lab, needs the VPN on: rejected |
| B. ntfy.sh (the public service) as the whole path, the topic name as the only secret | no server to run, but the alert text passes through a third party and the only guard is a long topic name; [ADR 0012](0012-observability.md) kept alerts on infrastructure I control. Not built |
| C. ntfy on the public side, behind nginx, closed by default, two logins | built: `ntfy.<domain>` on 443 like the other web names; nothing reachable without a login |
| D. Mail only | the base: the mail is always sent |

I built C. Two logins with the least each needs: `phone` can only read the `alerts` topic and `bridge` (Alertmanager's bridge) can only write it. `auth-default-access = deny-all`, so a topic nobody was granted is closed whatever its name. nginx limits requests per address (10 a second, a burst of 30). Critical alerts go to mail and push; the others by mail only.

Measured in the lab host (`lab/experiments/push-public-u13.sh`), against the LAN address, no VPN:

| Test | Result |
|---|---|
| A stranger: the web page, `/v1/health` | 200, 200 (they show nothing about the topics) |
| A stranger reads, writes, or guesses another topic | 403, 403, 403 |
| `phone` reads `alerts` / writes it / reads another topic | 200 / 403 / 403 |
| `bridge` writes `alerts` / reads it | 200 / 403 |
| 60 wrong passwords in a row | 401, then 429 (ntfy's own limit) and 503 (nginx's); then the right login is refused for a while (200 after 60 s): an address that guesses is locked out for about a minute, and a legitimate login from the same address with it |
| 200 requests at once, no login | 5 × 200, 195 × 503 |
| A critical alert end to end | push and mail both arrived, within about a minute |
| An open subscription through nginx (the phone's mode), a message posted meanwhile | received in 3 s |
| What leaves for ntfy.sh with the iPhone relay on | one empty POST, named by a hash of the topic, with a message id: no text, no topic name, no title. Off by default (`tidepool.push.iphoneRelay`); Android needs none |
| Cost | ntfy 71 MiB, the bridge 27 MiB |

Limits: the DNS name `ntfy.<domain>` must exist; the logins are two long random passwords (in the sops file, typed once into the phone app); the web page of ntfy is public (it is a static page); the app on an iPhone needs the relay; not tried on a real phone.

The phone side, on an Android without Google services: there is no Firebase push, so the ntfy app keeps one connection of its own to `ntfy.<domain>` (a foreground service with a small permanent notification). That is exactly what the public ntfy serves, and `iphoneRelay` stays off. Install the app from F-Droid (the build without Firebase), set battery to "Unrestricted" so the system does not stop the service, and log in as `phone`. Another VPN being on or off does not matter, because the server is reached over the Internet like any web name.

## 4. The NAS

`modules/nas.nix` (off by default, `tidepool.nas.enable`): Samba and Avahi, LAN interface only, macOS-friendly (`vfs_fruit`); the share on the mid-size disk; an optional Time Machine share on the large disk's partition (not backed up: replaceable, [ADR 0005](0005-storage-layout-and-filesystem.md)), advertised to the Mac by Avahi. Measured (`lab/experiments/nas-u14.sh`):

| Test | Result |
|---|---|
| Put, make a folder, list, on both shares | works; the files are owned by the share's user |
| Wrong password / no guest | `NT_STATUS_LOGON_FAILURE` / `NT_STATUS_ACCESS_DENIED` |
| Firewall | 445 and 5353 open only on the LAN interface (Avahi's own default opens 5353 on every interface; `openFirewall = false` and one rule per port fix it) |
| Avahi | the `_smb._tcp` and `_adisk._tcp` records are published |
| The share and the Samba users' database in the Borg job of everything | the archive lists the NAS file and `passdb.tdb`; the Time Machine file is not in it |
| Cost | Samba 11 MiB, Avahi 1 MiB |

With WiFi the share's address arrives late, and Samba's `bind interfaces only` fixed its addresses at the start: it is off now and the Samba units wait for the network and retry ([ADR 0019](0019-the-real-machine-network-and-hardware.md)); the firewall alone limits 445 to the LAN interface.

The Samba user's password has no declarative path in the module (`smbpasswd` is a command). I chose one manual step at deployment (`smbpasswd -a <user>`, in the runbook), not an exception: the password database lives in `/var/lib/samba`, which is in the Borg job, so a restore brings it back. Declaring it would be a small unit reading a sops secret, exception 3, not built.

## 5. Found on the way: listeners

Listing the host's sockets showed Valkey on every interface (6379), Immich on every interface (2283 and a worker port), and Alertmanager's gossip port (9094). The firewall blocked them, but a listener nobody needs is a second thing that has to hold. Now Valkey binds to `127.0.0.1`, Immich and its machine-learning container to loopback (`IMMICH_HOST`), and Alertmanager has no gossip port. After the change the host listens beyond loopback only on SSH (open to the VPN interface only), 80 and 443, Syncthing 22000, Samba 139 and 445 (LAN), port 8443 on the VPN address and the container bridges' DNS.

## 6. Before the repository becomes public

The history was scanned for the domain, the dynamic-DNS name, the router address, age keys, private-key blocks and tokens, and rewritten where something was found. GitHub may keep old commits reachable by hash for a while after a force push, so the safest way to publish is from a fresh repository, pushing only the branches and tags that should be public, and repeating the scan on what is pushed. The old scripts (tag `v0`) are to be fixed or left out of the public repository.

## 7. The differences the watch found: what to do

In its first run the watch found packages where nixpkgs, not the flake, is late. Updating `flake.lock` does not help: the stable channel carries the same versions as the lock, and unstable is behind too, except Borg. The ways out, each tried or measured:

| Way | Cost | Verdict |
|---|---|---|
| A. Wait and bump the lock weekly (the watch keeps saying so) | nothing | the default; right for bug fixes of non-exposed tools. A merged update arrives with the next lock bump (measured medians: 1.8 days for Nextcloud and 4.5 for Syncthing, worst case 32 days) |
| B. Override the package in the flake (`overrideAttrs` with the new version, the source hash and, for Go programs, the module hash) | tried for Syncthing: 3 steps (two hashes come from failed builds), 2 minutes in all; the result runs the new version. A line to remove by hand when nixpkgs catches up: nothing would tell | works, but each override is a debt and a departure from P1. Use it only when a release fixes a security problem and nixpkgs is late; record it in the exceptions register with the condition to drop it |
| C. Take that one package from nixos-unstable (a second input) | a second nixpkgs in the closure | possible, but a hybrid (P1 says no hybrids); the same debt as B, with a larger closure |
| D. Cherry-pick the open pull request as a patch in an overlay | a fetched patch that goes away when merged | the same debt as B, but self-announcing: when merged the patch no longer applies and the build fails loudly; the best of the three overrides |
| E. Help it merge: review or give a thumbs-up to the pull request | free | slow and not mine to decide |

My policy: A for everything that has no security fix in what is missing; D for a package whose missing release carries a security fix, dropped when merged; for Podman, A, moving to 6.x with 26.11. Each override is an exception to P1 and nothing was applied.

## 8. Can Nextcloud and PostgreSQL move to their newer majors now?

What the watch does when upstream has a major that nixpkgs lacks, or has: the monthly mail names every application for which a newer line exists upstream, without saying whether nixpkgs already packages it (the check is one command: `nix eval nixpkgs#nextcloud35.version`). Three situations: nixpkgs has the new major (the mail is a reminder and adopting it is a deliberate step); upstream has it and nixpkgs does not (the same reminder, and nothing to do but wait); nixpkgs drops the old major before I move (the build stops loudly, [ADR 0016](0016-updates-deploys-and-checks.md), and the end-of-life line of the monthly mail warns earlier). There is no list of "held" majors; the monthly reminder stays as it is.

Tried in the lab host (`lab/experiments/majors-u15-nextcloud.sh`, `majors-u15-postgres.sh`, `majors-u15-postgres-check.sh`; the lab's data is small, a few tens of MB per service, with no third-party Nextcloud apps and no registered single-sign-on clients):

| Move | Result |
|---|---|
| Nextcloud 33 to 34 (the module forbids skipping a major) | 31 s for the rebuild and the database update; the test file, nginx's `status.php` and the `oidc` app unchanged |
| Nextcloud 34 to 35 | 66 s; same checks, same result |
| PostgreSQL 17 to 18 with `pg_upgrade` (copy mode, 46 MB of data) | `--check` clean; the move itself 10 s; the switch of the configuration 41 s; every one of the 256 tables has the same row count in the old and the new cluster; the two VectorChord indexes are there and answer a vector query; Immich, Vaultwarden and Nextcloud answer on 18 |
| pgBackRest after the major | writes fail until `stanza-upgrade` (instant); then `check` passes, a full backup of 18 took 99 s, `verify` passes, and the monthly restore test passes (28 s); the old backups stay in the repository under the old database id |
| The way back to 17 (the old cluster is untouched in copy mode) | switch to the 17 configuration 29 s; archiving fails until `stanza-upgrade` is run again; then `check` is clean and the services answer |

Things to know: PostgreSQL 18's `initdb` turns data checksums on by default and `pg_upgrade` needs the setting to match, so the lab's upgrade created the new cluster with `--no-data-checksums`. `pg_upgrade` needs both the old and the new binaries with their extensions (`withPackages`), and `shared_preload_libraries=vchord.so` on both servers. Copy mode needs room for a second copy of the data; `--link` avoids it but makes the old cluster unusable once the new one starts, so the way back would then be a ZFS snapshot of the database dataset (50 ms to take, measured in ADR 0016). The times scale with the data: the lab's are lower bounds. And `pg_stat_user_tables` row counts read 0 after an upgrade (the statistics restart), so the exact counts above are what was compared.

What I decided for a real deployment:

- Nextcloud starts at 33, the major the migrated data is on, since it will not skip a major. Then 34 and 35 are two separate deploys, each about a minute, each preceded by a ZFS snapshot (a Nextcloud upgrade cannot be undone by NixOS). I go to 34 once the deployment has settled, and to 35 when nixpkgs has a 35.0.x with a few point releases behind it.
- PostgreSQL 17 for now. Starting on 18 would cost nothing, because the target database is built from a dump and not upgraded in place, but the dump restore of ADR 0006 and the full restore drill of [ADR 0014](0014-automation-and-restore-drill.md) were run on 17 and would have to be repeated on 18 first. The move later is a known 10-second procedure with the steps above.

## Decisions

1. The version watch's window: 3 days (worst case about 8.3 days from release to mail).
2. The Samba password: one manual step, built; a sops-fed unit would be exception 3.
3. Android without Google services for push: no relay, no request to ntfy.sh.
4. Major reminders: no "held" list; the monthly reminder stays.
5. Nextcloud 33 and PostgreSQL 17 for now; the moves to newer majors come later, as separate deploys through the same pipeline, with a snapshot of the data before each.
6. The open points of ADR 0016 are answered in [ADR 0018](0018-deploys-by-the-server.md): two merges, Renovate on the server, the cadence, the backups as the rollback point, 26.05 first, a deploy started by the server.

## Consequences

- `nix flake check` also runs the unit test of the version rules.
- The container pins carry their version in the pin; a Renovate update moves both.
- The public `tidepool` example host enables the NAS and push with example values; the real values come from the private repository.
- Nothing here was deployed on real hardware when this was written.
