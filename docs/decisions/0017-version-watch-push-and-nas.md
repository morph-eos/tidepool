# 0017. The version watch, push notifications without the VPN, and the NAS

- **Status:** accepted as built (2026-10-03) for the owner's three requests, **proposed** for the choices marked "open" at the end; measured in the lab, not on the real machine
- **Date:** 2026-10-03
- **Phase:** 8, Updates and automation (follow-up of [ADR 0016](0016-updates-deploys-and-checks.md))

## Context

After [ADR 0016](0016-updates-deploys-and-checks.md) the owner answered and asked for more (2026-10-03):

1. **Nextcloud, Vaultwarden and WebDAV in containers instead of NixOS modules?** Asked as a way to end the "module goes stale" problem. **Decided: no, keep the modules** (below).
2. **A weekly alert** that says, **every weekend**, when a new release exists upstream of **any application** and the module (or the container) **has not followed it for at least a week**; security patches and majors alike; modules **and** containers. If it cannot be done cleanly it may become **a third exception** ([exceptions.md](../exceptions.md)).
3. **Push notifications without the VPN:** the phone mainly runs Proton VPN, and the server must not become the VPN for everything.
4. **The NAS into the flake** (yes), and "measure everything about the VPN and push".
5. **The public repository will become public** once everything is on the server and the old scripts' security problems are fixed ([ADR 0003](0003-secrets.md) is updated).

## 1. Modules or containers for Nextcloud, Vaultwarden and WebDAV

**Considered before:** [ADR 0011](0011-services.md) (modules where the module is current), [ADR 0016 section 2](0016-updates-deploys-and-checks.md) (the exit from a module to the official container was **tried**, `lab/updates-u11.sh`: it works on the same data and database).

| | Module (kept) | Official container |
|---|---|---|
| Version lag | nixpkgs lag, **measured median 1.8 days for Nextcloud, 0.7 for Vaultwarden** | none by design, **but the digest only moves when someone moves it** (a pull request, a bot that is not decided yet) |
| Nextcloud's configuration, the OIDC app, settings | declared in Nix (`extraApps`, `settings`): one file, reviewable | rebuilt by hand around the image: mounted files, an installed app, `occ` commands; the owner's judgement: **"much more complicated"** |
| Cron, PHP, caching, nginx integration | the module does them | a second container for cron, a PHP image choice (apache or fpm), the proxy by hand |
| WebDAV | **is not a service**: it is nginx's own `dav` module (a few lines in the vhost) | would add a server where there is none |
| The "stale" signal | needed: **section 2** | needed too (a pin that nobody moves is the same problem) |

**Decision (the owner, 2026-10-03): keep the modules**; the containers already in the flake (Immich, Jellyfin, Valkey) stay as they are. A container would not have removed the need for a signal: it would have moved it from "nixpkgs is late" to "nobody bumped the pin". The escape hatch stays documented and tested.

**A correction to ADR 0016:** it said the stable branch carries two Nextcloud majors (33 and 34). The branch locked in the lab (2026-09-28) carries **33.0.9, 34.0.4 and 35.0.0**. The module still refuses to skip a major, so 33 to 35 is two steps.

## 2. The version watch

### Requirement, as the owner stated it

Every weekend, check every application; if upstream has had a newer release for **at least a week** and the running system does not have it, send **one mail**. Majors count. Containers count.

### Options considered

| Option | Tested how | Result |
|---|---|---|
| **A. Repology** (compares each repository with the newest upstream) | the real API for Nextcloud, Vaultwarden, Syncthing, Immich, Jellyfin, PostgreSQL, nginx, Valkey | **rejected.** It files Nextcloud as `nextcloud-unclassified` with one entry per major, all `outdated` against the newest major (35); Jellyfin 10.11 on the stable branch is `outdated` against 12.1; PostgreSQL 17 is `legacy`. **It cannot tell a missing patch from a newer major**, and Repology has its own lag. |
| **B. GitHub's "latest release" for everything** | the real API for nine projects (five by hand, four through the exporter in the lab host) | **used for the apps with one line** (Vaultwarden, Syncthing, Immich, Jellyfin, ntfy, Borg, pgBackRest, Incus). Not enough alone: it gives the newest release of the project, **not of the line that runs** (Nextcloud 33 against 35.0.1); the JSONPath of json_exporter has no regular expression to pick a line from the release list. |
| **C. endoflife.date** (the newest release **of each line**, with its date and whether the line is end of life) | the real API for 21 names: 10 exist | **used where it has the product:** Nextcloud, PostgreSQL, nginx, Linux, OpenZFS, Podman, Samba. Not there (tested): Vaultwarden, Syncthing, Immich, Jellyfin, Incus, ntfy, Borg (hence B). It also gives the **end of life** of the running line for free. |
| **D. A script** (a timer that compares and mails) | not built | would be **exception 3**. Not needed: C and B plus the rules below do it with zero scripts. |
| **E. Renovate** (pull requests for pins) | ADR 0016 | **complementary, not a substitute:** it moves pins, it does not tell that a module is behind. |

### How it works (all declared in Nix; no script)

- **Deployed versions** are written by `modules/versions.nix` into a text file read by the node exporter: they come from the **packages and image tags of the system generation** (`config.services.nextcloud.package.version`, `config.boot.kernelPackages.kernel.version`, the tag of each container pin). So the watch compares what is **really** in the running generation, not what a service says about itself. For this to work the container pins are now **`repo:tag@sha256:...`** (the tag is the version, the digest is the pin; a Renovate update moves both) instead of a digest with a comment.
- **Upstream versions** are read once an hour by the NixOS module of **json_exporter** (9 MiB) from endoflife.date and from GitHub (a handful of requests an hour against GitHub's 60 without a login).
- **The rules** (`modules/versions/rules.yml`): the **newest stable release** of the line that runs is `tidepool:upstream_mine` (GitHub's latest release, which **excludes pre-releases**: checked on Syncthing, whose list starts with `v2.1.6-rc.4` while "latest" is `v2.1.5`; or endoflife.date's newest release of the running line). Recording rules say 1 or 0 every five minutes: *actionable* (upstream is ahead **and nixpkgs already has that version, or the app does not come from nixpkgs**: a lock bump or a new pin fixes it), *waiting* (upstream is ahead **and nixpkgs does not have it yet**: nothing to bump), *major behind* (a newer line exists) and *line end of life*. Two tiers of alerts, **only on Saturday and Sunday from 07:00 UTC**, each needing its **whole window of samples**: **weekly**, `UpstreamReleaseNotDeployed` (actionable for **3 days**); **monthly, the first weekend of the month only**, `NixpkgsBehindUpstream` (waiting for **14 days**), `UpstreamMajorNotAdopted`, `RunningLineEndOfLife`. `VersionWatchBlind` warns if a source cannot be read for a day (silence would otherwise look like "all current"). What nixpkgs has comes from **Repology** (the version of the stable branch, by a filter on the branch; the rules pick the package by its version).
- **One mail per tier:** the `weekly` and `monthly` alerts are grouped by tier into a single mail each (`[FIRING:3] weekly (...)`), repeated only after 47 hours, and nothing is sent on "resolved".
- **Covered:** Nextcloud, PostgreSQL, nginx, Vaultwarden, Syncthing, Borg, pgBackRest, Immich, Jellyfin, the kernel, OpenZFS, Podman, Incus, Samba (with the NAS), ntfy (with push). **Not covered, on purpose or not yet:** Nextcloud's own apps (the OIDC app), Valkey (its tag is a major line, `8-bookworm`, and it is Immich's private cache), the base images' operating-system packages, and **the CVEs themselves** (the watch says a release exists, not that it fixes a vulnerability).

### Measured

- **Unit test of the rules** (`modules/versions/rules.test.yml`, `promtool test rules`): 39 days of synthetic series and 18 checks (the cases are listed under "Is it the newest stable" below). It is a **flake check** (`versions-rules`), so it runs on every `nix flake check`, and **it fails when a rule is broken** (tried twice: removing the "full window" condition, and widening the monthly gate).
- **A flaky test found and fixed:** one run in fifteen failed. Cause: Prometheus 3 leaves the sample of exactly five minutes ago out of an instant lookup, so an alert that reads a recorded value can see nothing at the moment the recording is a few milliseconds late. The one rule that read an instant value now reads `last_over_time(...[15m])`; **0 failures in 40 runs** afterwards. (In production the same race would have dropped one alert evaluation in a while: harmless for a weekly alert, but a flaky test is a bug.)
- **End to end in the lab host, against the real APIs** (the lab's lock is from 2026-09-28): the node exporter serves the deployed versions, json_exporter answers for all targets, the rules load. The watch **found three real laggards on the stable branch**: **Syncthing 2.1.3 against 2.1.5** (released 2026-09-08, about 25 days), **Borg 1.4.4 against 1.4.5**, **pgBackRest 2.58.0 against 2.59.2**, plus **Samba 4.23.10 against 4.23.13**; and it found that **Podman's 5.8 line is end of life upstream** while 26.05 ships it. Nextcloud 33.0.9, PostgreSQL 17.11, nginx 1.30.5, Vaultwarden 1.37.3, Immich 3.2.4 and the kernel's 6.18.54 are current. Majors available: Nextcloud (34, 35) and PostgreSQL (18).
- **The weekly mail:** three alerts posted together gave **one** mail, `[FIRING:3] weekly (UpstreamReleaseNotDeployed)`, after the 5-minute group wait; no mail when they expired.
- **Cost:** json_exporter 9 MiB; 376 more series in Prometheus (the lists of old end-of-life lines of endoflife.date are most of it); nothing on disk to keep.

### What it does **not** give (honestly)

- **The first mail can come late.** The window is "behind for **three** days since the watch first saw it" (the owner chose 3 on 2026-10-03; 7 was the first figure), the mail is sent on the next weekend: a release on a Friday waits **about 8.3 days**, one on a Wednesday about 3.3; a 7-day window would have been 12.3 days at worst.
- **Major reminders repeat every weekend** for as long as a major is not adopted (today: Nextcloud and PostgreSQL). That is what was asked ("also the majors"); a deliberate hold (PostgreSQL 17 while Immich says so) will be a standing weekly line. A "held major" setting (an acknowledged line, with a date) can be added if it becomes noise.
- **Distribution-maintained packages** such as Podman 5.8 may be patched by nixpkgs although upstream ended the line; the alert will say "end of life" regardless. Drop the app from the list if it is noise.
- **It watches two external services** (endoflife.date, GitHub); if either disappears the watch goes blind and says so after a day.
- **Exceptions: none.** This is not exception 3; the register still has two entries.

### Is it the newest stable, and will it be spam? (the owner asked, 2026-10-03)

**The newest stable, yes, with two limits.** Pre-releases are excluded at the source (GitHub's latest release; endoflife.date's list of releases). The check follows **the line that runs**: for Nextcloud, PostgreSQL, nginx, the kernel, ZFS, Podman and Samba it asks for the newest release **of that line** and, separately, whether a **newer line** exists. Two things it does not do: it does not follow **LTS against feature releases** (Incus runs the 7.0 LTS while GitHub's latest is the 7.5 feature line, so **Incus is not watched**), and it does not read **security advisories**.

**The first version would have been spam.** With today's data it would have mailed **about seven lines every weekend** (Samba, Borg, pgBackRest, Syncthing, Nextcloud's and PostgreSQL's majors, Podman's end of life), and **none of the first four could be fixed by the owner**: nixpkgs itself is behind (section 8). That is the kind of mail that gets ignored. So the mail now has **two tiers**:

| Tier | When | What | Today (lab data) |
|---|---|---|---|
| **Weekly** | every weekend | upstream has a newer stable release for 3 days **and nixpkgs has it already** (or the app is a container pin): something you can do | nothing |
| **Monthly** | the first weekend of the month | nixpkgs behind upstream for **14 days**; a newer **major** exists; the running line is **end of life** | Borg, pgBackRest, Samba, Syncthing, ntfy (waiting); Nextcloud and PostgreSQL (majors); Podman (end of life) |

An item moves from monthly to weekly **the moment nixpkgs gets the version**: the mail then says "bump the lock", which is the action. Measured: the unit test (39 days of synthetic series, 18 checks, about a minute) covers an app waiting for nixpkgs, one that nixpkgs then catches up on, one stalled only 4 days, an override (deployed equals upstream while nixpkgs is older: silent), and the weekend, first-weekend and 07:00 gates; **it fails when the monthly gate is widened** (tried). On the real data of the lab host the recording rules gave: actionable for none of the nixpkgs-fed apps, waiting for Borg, pgBackRest, Samba and Syncthing, majors for Nextcloud and PostgreSQL, Podman end of life.

**What remains noisy:** the monthly mail will keep naming Nextcloud's and PostgreSQL's majors until they are adopted or a "held major" setting is added, and Podman's end of life until 26.11. **The lag between Repology and nixpkgs** (hours to a day or two) is covered by the 3-day window.

## 3. Push notifications without the VPN

### Why not the VPN

Android and iOS run **one VPN at a time** ([Timus support](https://support.timusnetworks.com/hc/en-us/articles/42332497622291-Why-Running-Two-VPNs-on-the-Same-Device-Can-Be-Problematic); [a request to Proton for two at once](https://protonmail.uservoice.com/forums/932836-proton-vpn/suggestions/47324555-split-tunneling-two-different-vpn-connections-sim)); with Proton VPN on, the server's WireGuard would be off, so a VPN-only ntfy would receive nothing. This was **not tried on a phone** here: it is the platform's documented behaviour. The prototype of ADR 0016 (ntfy on the WireGuard address) therefore does not meet the requirement.

### Options

| Option | Result |
|---|---|
| **A. ntfy on the VPN address only** (ADR 0016's prototype) | works in the lab, **needs the VPN on**: rejected by the owner's requirement |
| **B. ntfy.sh (the public service) as the whole path**, topic name as the only secret | no server to run, but the **alert text passes through a third party** and the only guard is a long topic name; [ADR 0012](0012-observability.md) kept alerts on infrastructure the owner controls. Not built. |
| **C. ntfy on the public side, behind nginx, closed by default, two logins** (**built**) | `ntfy.<domain>` on 443 like the other web names; **nothing reachable without a login**; below |
| **D. Mail only** (no push) | the status quo; kept as the base: the mail is **always** sent |

### Built: C

Two logins with the least each needs: **`phone` can only read** the `alerts` topic and **`bridge` (Alertmanager's bridge) can only write** it. `auth-default-access = deny-all`, so a topic nobody was granted is closed whatever its name. nginx limits requests per address (10 a second, a burst of 30). Critical alerts go to mail **and** push; the others by mail only.

Measured in the lab host (`lab/push-public-u13.sh`), against the LAN/public address, no VPN:

| Test | Result |
|---|---|
| A stranger: the web page, `/v1/health` | 200, 200 (they show nothing about the topics) |
| A stranger reads, writes, or guesses another topic | **403, 403, 403** |
| `phone` reads `alerts` / writes it / reads another topic | 200 / **403** / **403** |
| `bridge` writes `alerts` / reads it | 200 / **403** |
| **60 wrong passwords in a row** | 30 × 401, 17 × 429 (ntfy's own limit), 13 × 503 (nginx's); then **the right login is refused** for a while (429 after 5 s and 20 s, **200 after 60 s**): an address that guesses is locked out for about a minute; **a legitimate login from the same address is locked with it** |
| 200 requests at once, no login | 5 × 200, **195 × 503** |
| A critical alert end to end | **push and mail both arrived**, within about a minute |
| An open subscription through nginx (the phone's mode), a message posted meanwhile | received in 3 s |
| **What leaves for ntfy.sh** with the iPhone relay on (a listener stood in for ntfy.sh) | **one empty POST, named by a hash of the topic, with a message id**: no text, no topic name, no title. Off by default (`tidepool.push.iphoneRelay`); **Android needs none**. |
| Cost | ntfy 71 MiB, the bridge 27 MiB |

**Limits:** the DNS name `ntfy.<domain>` must exist; the logins are two long random passwords (in the sops file, typed once into the phone app); the web page of ntfy is public (it is a static page); the app on an iPhone needs the relay; the **Pebble ACME order for the new name failed in the lab** (`accountDoesNotExist`, a throwaway CA that had restarted: not a finding about the module; the tests told curl to ignore the certificate); **not tried on a real phone**.

## 4. The NAS, built

`modules/nas.nix` (off by default, `tidepool.nas.enable`): Samba and Avahi, **LAN interface only**, macOS-friendly (`vfs_fruit`); the share on the 2 TB disk (`/mnt/big2tb/nas`); an optional **Time Machine** share on the 16 TB disk's partition (**not backed up**: replaceable, [ADR 0005](0005-storage-layout-and-filesystem.md)), advertised to the Mac by Avahi. Measured (`lab/nas-u14.sh`):

| Test | Result |
|---|---|
| Put, make a folder, list, on both shares | works; the files are owned by the share's user |
| Wrong password / no guest | `NT_STATUS_LOGON_FAILURE` / `NT_STATUS_ACCESS_DENIED` |
| Firewall | 445 and 5353 open **only on the LAN interface** (Avahi's own default opens 5353 on every interface; `openFirewall = false` and one rule per port fix it) |
| Avahi | the `_smb._tcp` and `_adisk._tcp` records are published |
| **The share and the Samba users' database in the Borg job of everything** | the archive lists the NAS file and `passdb.tdb`; **the Time Machine file is not in it** |
| Cost | Samba 11 MiB, Avahi 1 MiB |

**The Samba user's password has no declarative path** in the module (`smbpasswd` is a command). Decision taken here: **one manual step at deployment** (`smbpasswd -a nas`, in the runbook), **not an exception**: the password database lives in `/var/lib/samba`, which is now in the Borg job, so a restore brings it back. If the owner wants it declared, that would be a small unit reading a sops secret: **exception 3, not built**. **Open decision 2.**

## 5. Found on the way: listeners

Listing the host's sockets showed **Valkey on every interface (6379), Immich on every interface (2283, and a worker port), and Alertmanager's gossip port (9094)**. The firewall blocked them (it opens 80 and 443, Syncthing's ports, SSH and 8443 on the VPN interface, and the NAS ports on the LAN interface), but a listener nobody needs is a second thing that has to hold. Now Valkey binds to `127.0.0.1`, Immich and its machine-learning container to loopback (`IMMICH_HOST`), Alertmanager has no gossip port. After the change the host listens beyond loopback only on **SSH (open to the VPN interface only), 80/443, Syncthing 22000, Samba 139/445 (LAN), port 8443 on the VPN address and the container bridges' DNS**; Immich answers through the proxy as before.

## 6. Before the repository becomes public

- **Done:** the owner's domain was in **one commit** (`nixos/private/domain` of the services experiment, on `exp/services-native` and `exp/observability` and their tags). The commits were **rewritten** (the file now holds `example.org`), re-signed, the branches and tags force-pushed, and the old objects removed from the local clone. A scan of every commit of every branch and tag for the domain, the dynamic-DNS name, the router address, age keys, private-key blocks and tokens finds **nothing else**.
- **Still to do:** GitHub may keep the old commits reachable by their hash for a while after a force push. **Safest: publish from a fresh repository** (create a new public one and push only the branches and tags that should be public) rather than flipping this one. The scan must be repeated on what is pushed.
- **The old scripts** (`main`, tag `v0`) are what the owner means by "security problems": they are to be fixed or left out of the public repository; this ADR did not audit them beyond the secret scan above.

## 7. The phone: Android with GrapheneOS

GrapheneOS has **no Google services by default**, so there is no Firebase push: the ntfy app keeps **one connection of its own** to `ntfy.<domain>` (a foreground service with a small permanent notification). That is exactly what the public ntfy serves, and **`iphoneRelay` stays off** (nothing goes to ntfy.sh). Install the app from **F-Droid** (the build without Firebase) and, in the app's settings, set **battery to "Unrestricted"** so the system does not stop the service; log in as `phone`. Proton VPN on or off does not matter, because the server is reached over the Internet like any web name. **Not tried on a real phone.**

## 8. The differences the watch found: what to do

The measurements of 2026-10-03, and what each version fixes (the release notes):

| App | Running | Upstream | Stable branch today | Unstable today | In nixpkgs | What the release fixes |
|---|---|---|---|---|---|---|
| Syncthing | 2.1.3 | 2.1.5 (2026-09-08) | 2.1.3 | 2.1.3 | the package update is **not in** a pull request that I found (only the relay and discovery packages have one) | nothing marked security in 2.1.4 or 2.1.5 |
| **Borg** | 1.4.4 | 1.4.5 (**2026-07-18**) | 1.4.4 | **1.4.5** | a backport to 26.05 has been **open since 2026-09-01** | "some fixes **including a low-severity security fix**" |
| pgBackRest | 2.58.0 | 2.59.2 | 2.58.0 | 2.58.0 | none found | 2.59.1 and 2.59.2: bug fixes (a hang; a truncated file during a backup) |
| Samba | 4.23.10 | 4.23.13 | 4.23.10 | 4.23.10 | none found | not read; Samba publishes its security releases at samba.org/samba/security |
| Podman | 5.8.7 | 6.1.3 (5.8 is end of life) | 5.8.7 | 5.8.7 | pull requests to 6.1 are open since 2026-09-12 and 2026-09-25 | the line is out of upstream support |

**Updating `flake.lock` does not help today**: the stable channel carries the same versions as the lock (checked), and unstable is behind too, except Borg. The lag is **nixpkgs's**, not ours.

The ways out, each tried or measured:

| Way | Cost | Verdict |
|---|---|---|
| **A. Wait** and bump the lock weekly (the watch keeps saying so) | nothing | the **default**; right for bug fixes of non-exposed tools (pgBackRest, Samba). A merged update arrives with the next lock bump (the measured medians were 1.8 days for Nextcloud and 4.5 for Syncthing, with a worst case of 32 days for Syncthing; today's gaps are weeks) |
| **B. Override the package in the flake** (`overrideAttrs` with the new version, the source hash and, for Go programs, the module hash) | **tried for Syncthing: 3 steps (two hashes come from failed builds), 2 minutes in all** (46 s to find the module hash, 69 s to build); the result runs as `syncthing v2.1.5`. **A line to remove by hand** when nixpkgs catches up: nothing would tell (the watch compares with upstream, not with the override) | **works, but each override is a debt and a departure from P1** (a hand-kept version). Use it only when a release fixes a security problem **and** nixpkgs is late; record it in the exceptions register with the condition to drop it |
| **C. Take that one package from nixos-unstable** (a second input) | for Borg: 1.4.5 is there; a second nixpkgs in the closure | possible; **a hybrid** (P1 says no hybrids); the same debt as B, with a larger closure |
| **D. Cherry-pick the open pull request** as a patch in an overlay | a fetched patch that goes away when merged | the same debt as B, but **self-announcing**: when merged the patch no longer applies and the build **fails loudly**; the best of the three overrides |
| **E. Help it merge:** review or give a thumbs-up to the pull request | free | slow and not ours to decide |

**Recommendation:** A for pgBackRest, Samba and Syncthing (no security fix in what is missing); **for Borg, D** if the low-severity fix matters to the owner (the backport PR as an overlay patch, dropped when merged), otherwise A; **Podman: A**, moving to 6.x with 26.11 (the watch will keep saying the 5.8 line is end of life until then; that line is the owner's decision 5 below). **Nothing was applied**: each override is an exception to P1 and is the owner's call.

## 9. Can Nextcloud and PostgreSQL move to their newer majors now? (the owner asked, 2026-10-03)

**What the watch does when upstream has a major that nixpkgs lacks, or has:** the monthly mail names every application for which a newer line exists upstream, **without saying whether nixpkgs already packages it** (that is a limit; the check is one command: `nix eval nixpkgs#nextcloud35.version`). Three situations: (1) nixpkgs **has** the new major (today: Nextcloud 34 and 35, PostgreSQL 18): the mail is a reminder, and adopting it is a deliberate step; (2) upstream has it and nixpkgs **does not**: the same reminder, and nothing can be done but wait; (3) nixpkgs **drops** the old major before the owner moves: the build **stops loudly** ([ADR 0016](0016-updates-deploys-and-checks.md)), and the end-of-life line of the monthly mail warns earlier. **Decided by the owner: no list of "held" majors**; the monthly reminder stays as it is.

**Tried in the lab host** (`lab/majors-u15-nextcloud.sh`, `lab/majors-u15-postgres.sh`, `lab/majors-u15-postgres-check.sh`; the lab's data is small: Nextcloud 16 MB, Immich 35 MB, Vaultwarden 9 MB; it has no real v0 data, no third-party Nextcloud apps and no registered single-sign-on clients):

| Move | Result |
|---|---|
| **Nextcloud 33.0.9 to 34.0.4** (the module forbids skipping a major) | **31 s** for the rebuild and the database update; version 34.0.4.1; the test file, nginx's `status.php` and the `oidc` app (2.3.1, packaged for all three majors) **unchanged** |
| **Nextcloud 34 to 35.0.0** | **66 s**; version 35.0.0.10; same checks, same result |
| **PostgreSQL 17.11 to 18.6** with `pg_upgrade` (copy mode, 46 MB of data) | `--check` clean; the move itself **10 s**; the switch of the configuration **41 s**; **every one of the 256 tables has the same row count in the old and the new cluster (50,511 rows)**; the two VectorChord indexes (`vchordrq`) are there and answer a vector query; pgvector 0.8.2 and VectorChord 1.1.1 on both; Immich, Vaultwarden and Nextcloud 35 answer on 18 |
| **pgBackRest after the major** | writes fail until `stanza-upgrade` (instant); then `check` passes, a **full backup of 18 took 99 s** (190 MB, on a busy lab VM), `verify` passes, and **the monthly restore test passes (28 s)**; the old backups stay in the repository under the old database id |
| **The way back to 17** (the old cluster is untouched in copy mode) | switch to the 17 configuration **29 s**; archiving fails with "backup and archive info files exist but do not match the database" **until `stanza-upgrade` is run again**; then `check` is clean; Immich and Vaultwarden answer |

**Things to know:** PostgreSQL 18's `initdb` turns **data checksums on** by default and `pg_upgrade` needs the setting to match, so the lab's upgrade created the new cluster with `--no-data-checksums` (a cluster created on 18 from scratch has them: not a problem, but the two differ); `pg_upgrade` needs **both** the old and the new binaries with their extensions (`withPackages`), and `shared_preload_libraries=vchord.so` on both servers; copy mode needs room for a **second copy** of the data (`--link` avoids it but makes the old cluster unusable once the new one starts: the way back would then be a ZFS snapshot of `tank/postgres`, 50 ms to take and a few seconds to roll back, measured in ADR 0016); the **times scale with the data**: the lab's are lower bounds. The first run of the PostgreSQL script also showed that Prometheus-style "row counts" from `pg_stat_user_tables` read 0 after an upgrade (the statistics restart): the exact counts above are what was compared.

**For the real deployment** (the owner decides, nothing is applied):

- **Nextcloud: start at 33.** v0 runs `nextcloud:33-apache`; Nextcloud will not skip a major, so the first deployment must open v0's data at 33. **Then 34 and 35 are two separate deploys**, each about a minute, each preceded by a ZFS snapshot (a Nextcloud upgrade cannot be undone by NixOS, [ADR 0016](0016-updates-deploys-and-checks.md)). nixpkgs has **35.0.0**, upstream has 35.0.1: a `.0` release; 34.0.4 is the mature one. My recommendation: **go to 34 once the deployment has settled, to 35 when nixpkgs has a 35.0.x that has a few point releases behind it** (a judgement, not measured).
- **PostgreSQL: 18 from the first deployment would cost nothing and save the move later.** The target database is **built from v0's PostgreSQL 14 dump**, not upgraded from 17, so there is no `pg_upgrade` at all; Immich's documentation says it works with PostgreSQL 14 up to 19 ([ADR 0006](0006-postgresql-version-and-immich.md)), and the lab ran Nextcloud 35, Vaultwarden and Immich on 18. What is **not** done yet: the dump restore of ADR 0006 and the full restore drill ([ADR 0014](0014-automation-and-restore-drill.md)) were run on **17**; they must be repeated on **18** before ADR 0006 changes. **Open decision 7:** PostgreSQL 18 for the first deployment (needs the drill repeated), or 17 and the move later (a known 10-second procedure with the steps above).

## Decisions for the owner

1. ~~The window of the version watch~~ **decided 2026-10-03: 3 days** (worst case about 8.3 days from release to mail).
2. **The Samba password:** one manual step (built) or a sops-fed unit (exception 3).
3. ~~Android or iPhone~~ **decided 2026-10-03: Android with GrapheneOS** (see section 7): no relay, no request to ntfy.sh.
4. ~~Major reminders~~ **decided 2026-10-03: no "held" list**; the monthly reminder stays.
5. Whether the **Podman-style "line is end of life upstream"** line should stay for packages the distribution patches.
6. **What to do about the differences found** (section 8): wait (A) for everything, or D for Borg.
7. **PostgreSQL 18 from the first deployment** (the dump restore and the restore drill repeated on 18 first) or 17 now and the move later (section 9).
8. The items of [ADR 0016](0016-updates-deploys-and-checks.md) that remain open (design B, Renovate, cadence, rollback point, 26.05 or 26.11, human-started deploys).

## Consequences

- `nix flake check` now also runs the unit test of the version rules.
- The container pins carry their version in the pin; a Renovate update moves both.
- The public `tidepool` example host enables the NAS and push with example values; the real values come from the private repository.
- Nothing here is deployed on the real server.
