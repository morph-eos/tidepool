# What runs when

One table for every automatic job and alert of the integrated host (`nixos/`), read from the lab host's real timers on 2026-10-03, so that a change to one schedule can be checked against the others. Times are Europe/Rome. The reasons are in the ADRs named on the right; this file is the list, not the argument.

## Jobs

| What | When | Notes | ADR |
|---|---|---|---|
| Borg jobs `everything` (16 TB disk) and `offsite` (2 TB disk) | every hour, on the hour | create, then prune and compact; each waits **up to 12 hours** for the repository lock | [0004](decisions/0004-backup.md), [0015](decisions/0015-backup-verification.md) |
| Borg retention | at every job | every archive of the last **3 days**, then one a day until the 14th day, then one a week for 4 weeks (87 archives, the oldest about 40 days) | [0004](decisions/0004-backup.md) |
| PostgreSQL WAL archiving (pgBackRest) | continuous, at most 30 s behind (`archive_timeout`) | | [0004](decisions/0004-backup.md) |
| pgBackRest differential backup | Monday to Saturday, 03:00 | | [0004](decisions/0004-backup.md) |
| pgBackRest full backup | Sunday, 03:00 | two full backups kept, so a point-in-time restore reaches back **7 to 14 days** | [0004](decisions/0004-backup.md) |
| borgmatic checks: repository, extraction, **every byte of every archive**, on both repositories | **Sunday, 04:30** plus a random delay of a few minutes and the package's one-minute start delay; if the machine was off, at the next boot | the only schedule of the checks; the hourly Borg jobs wait for the lock meanwhile | [0015](decisions/0015-backup-verification.md) |
| Restore test of the databases (`pgbackrest-restore-test`) | monthly, plus up to 6 hours of random delay; at the next boot if missed | restores the latest backup into a scratch copy, checks it, deletes it | [0015](decisions/0015-backup-verification.md) |
| ZFS scrub of the SSD pool | monthly, plus up to 6 hours of random delay | | [0005](decisions/0005-storage-layout-and-filesystem.md) |
| ZFS pool trim, `fstrim` | weekly | | [0005](decisions/0005-storage-layout-and-filesystem.md) |
| Certificate renewal (one timer per name) | **daily, with a random delay of up to 24 hours** and an accuracy of 4 hours | the order renews when a third of the certificate's life is left (about 30 days for 90-day certificates) | [0008](decisions/0008-edge.md) |
| Nix store collection (`nix-gc`) | weekly (Monday 00:00); removes generations older than **14 days** | the system disk is 119 GB and a generation is 4.7 GiB; freed 12.4 GiB of leftovers in the lab test | [0016](decisions/0016-updates-deploys-and-checks.md) |
| Nix store deduplication (`nix-optimise`) | daily 03:45, up to 30 minutes of random delay | | [0016](decisions/0016-updates-deploys-and-checks.md) |
| Podman image prune | weekly, up to 30 minutes of random delay | removes untagged images no container uses (the old digest after an update) | [0016](decisions/0016-updates-deploys-and-checks.md) |
| Nextcloud background jobs | every 5 minutes | | [0011](decisions/0011-services.md) |
| Prometheus scrape and rule evaluation | every 30 seconds | | [0012](decisions/0012-observability.md) |

## Alerts and heartbeats

| What | Behaviour | ADR |
|---|---|---|
| A failed systemd unit (any backup, check, restore test, certificate order) | `UnitFailed`: mail after **5 minutes**; measured on a real failed backup: the mail arrived 6 minutes 13 seconds after the failure | [0012](decisions/0012-observability.md), [0015](decisions/0015-backup-verification.md) |
| A Borg job, borgmatic run or restore test **running for 8 hours** | `BackupJobRunningLong` | [0015](decisions/0015-backup-verification.md) |
| A timer that stopped firing | Borg jobs: 4 hours; pgBackRest: 60 hours; borgmatic (weekly): 8 days; restore test (monthly): 45 days; certificate renewal (daily, random up to 24 h): **3 days** | [0012](decisions/0012-observability.md), [0015](decisions/0015-backup-verification.md) |
| Alert mails | first mail after 30 seconds; new alerts in an existing group at most every **30 minutes**; a repeat every 12 hours while it keeps firing; no mail when an alert resolves | [0012](decisions/0012-observability.md) |
| **The version watch** ([ADR 0017](decisions/0017-version-watch-push-and-nas.md)) | upstream versions, and what nixpkgs has, read **hourly**; the rules judge every 5 minutes; alerts only on **Saturday and Sunday from 07:00 UTC**. **Weekly mail:** a newer stable release has been out for **3 days** and nixpkgs has it (or it is a container pin). **Monthly mail (first weekend):** nixpkgs behind upstream for 14 days, a newer major, a line at end of life. One mail per tier, no mail on "resolved"; `VersionWatchBlind` after a day without a source | 3 days: the owner's choice, 2026-10-03; the monthly tier answers "will it be spam every weekend?" |
| Push (ntfy) | critical alerts go to mail **and** the phone, within about a minute | [0017](decisions/0017-version-watch-push-and-nas.md) |
| **Deploys** ([ADR 0018](decisions/0018-deploys-by-the-server.md)) | the server looks **every 10 minutes, Monday to Saturday** (`system.autoUpgrade`; **never on Sunday**, so that the Sunday checks are not cut by a reboot); a tick with nothing new costs about 1 s of CPU; a change that differs from the running system is **built, preceded by Borg of everything, Borg offsite and a pgBackRest differential backup**, then activated; **any failure stops it** and fails the unit (`UnitFailed`, 5 minutes) | a merge to the public `main` or a push to the private `main`; no reboot by itself |
| A new kernel | **the machine reboots by itself between 06:00 and 07:00, Monday to Saturday** (the owner's choice; the module's default is off; no deploy tick on Sunday): a deploy with a new kernel is installed at once and **everything merged until then waits for the reboot** (about 20 s of downtime in the lab); `RebootPending` covers only the mode with the reboot off; a machine that does not come back is noticed by the heartbeat | the TPM case is untried and needs PCR 7 only, no PIN: [0018](decisions/0018-deploys-by-the-server.md) section 9, [0005](decisions/0005-storage-layout-and-filesystem.md) |
| Renovate (pull requests) | **on the server**, **Monday 04:30** (the pull requests are opened before 06:00): container pins grouped, `flake.lock`, Actions' commits; the token is a machine user's and **expires** (the unit then fails: `UnitFailed`) | [0018](decisions/0018-deploys-by-the-server.md) |
| Heartbeat by webhook (the machine and Alertmanager are alive) | every 2 minutes | [0012](decisions/0012-observability.md) |
| Heartbeat by mail through Brevo (the mail path works) | about every 6 hours (4 mails a day, counted in the 300-a-day budget) | [0012](decisions/0012-observability.md) |

## Why the pieces fit (the checks made on 2026-10-03)

- **Files and database restore to the same moment:** hourly files for 3 days, daily files for 14 days, and the database reaches back 7 to 14 days: the file history is never shorter than the database's by more than the hour-to-day step.
- **The Sunday sequence:** pgBackRest's full backup at 03:00 and the borgmatic checks at 04:30 touch the same 16 TB disk; the hourly Borg jobs queue behind the checks for as long as they last. **Not measured on real data.**
- **Every "stale" threshold is longer than the longest legitimate gap** of its timer (the certificate rule was 2 days and wrong: two runs can be almost 48 hours apart).
- **A long wait is not allowed to hide a hang:** the jobs wait 12 hours, and an 8-hour run warns.

## Proposed, not in the system yet ([ADR 0016](decisions/0016-updates-deploys-and-checks.md))

| What | When | Notes |
|---|---|---|
| Renovate: pull requests for container digests (and `flake.lock` if chosen) | weekly | the owner's weekly look at the pull requests and at the exposed services' advisories |
| `nix flake check` on every pull request and push | on each | a hosted runner fits it (4.1 GB of memory, 6.9 GB of disk, minutes) |
| Deploys | monthly, or when a serious advisory lands | by the owner, after the checks, with a ZFS snapshot of the two datasets first |
| The full restore drill | before each release move, after changes to storage, backup, database or Incus modules, and once a quarter | on the owner's workstation |
| Move to NixOS 26.11 | within weeks of its release (due 2026-11-30), before 26.05 ends on 2026-12-31 | |
