# 0004. Backups: the tool and the restore drill

- **Status:** accepted: pgBackRest through its NixOS module; no periodic snapshots; Borg every one to two hours for the files, into two repositories (an offsite one on the mid-size disk, one of everything on the large disk); retention of a few weeks
- **Date:** 2026-09-29, updated 2026-10-01
- **Phase:** 2, Backup

## Context

The previous setup has two independent Borg repositories: an offsite one (encrypted, mirrored to Proton Drive with the official CLI) and a local one of everything, which is not encrypted and holds an environment file with secrets. Databases are dumped before Borg runs (PostgreSQL for Immich, MariaDB for Nextcloud) and SQLite is snapshotted. What was not covered: Incus VM disks, `/etc`, the phone backups, the Syncthing identity, and the bulk of the media. No restore was ever rehearsed on a blank machine. The rule of this project is that backups come before data: nothing holds real data until a restore has been rehearsed.

## Requirements

- Must: a restore, done in the lab from an empty machine and a copy of the backup only, that brings back files and databases and is verified (not "the command ended"); encryption at rest for every copy, offsite included; no secret in clear text in any backup; the key or passphrase kept outside the server ([ADR 0003](0003-secrets.md)); a failed backup is noticed (mail or notification), and so is a backup that did not run.
- Should: consistent database backups (a dump or a snapshot, never a copy of a live data directory); a way to know a backup is restorable without a full drill each time (a periodic verification); an offsite copy that survives the loss of the house; retention of a few weeks; the host configuration is already in Git, so `/etc` needs no backup.
- Should not: back up the media library the same way as the family's data if it is not worth the space, or need a backup server with its own care.

## What I decided up front

- What must survive: the family's data for sure, and the media library too. The plan is to reorganize the storage so that the large disk becomes the backup target for everything, library included. So the backup design and the disk layout are one decision, not two.
- How much data may be lost: almost none for some services where possible (PostgreSQL with properly configured WAL archiving), a few hours where that is sensible. This replaces the previous single rule of "up to 24 hours" with tiers.
- The offsite destination: not decided, with a comparison wanted. Proton Drive stays a candidate, not a given (settled in [ADR 0007](0007-offsite-copy.md)).

| Tier | What | Target window | How it is reached |
|---|---|---|---|
| 1 | Databases: Immich and Nextcloud (PostgreSQL) | minutes, through point-in-time recovery | WAL archiving plus periodic base backups with restore to a chosen moment, or crash-consistent snapshots every few minutes |
| 1 | Vaultwarden (SQLite at first) | minutes | moved to PostgreSQL, so pgBackRest covers it and Borg never reads an open SQLite file |
| 2 | Family files: photos, documents, Nextcloud data, configuration | a few hours | Borg every one to two hours (incremental, encrypted, deduplicated) |
| 3 | Media library | a day or more is fine | a plain copy on the large disk; it does not go offsite |

## Options to consider

The question splits into three layers that can be chosen independently.

Layer 1, files (tiers 2 and 3):

| Option | Why it is a contender |
|---|---|
| A. BorgBackup through the NixOS module (`services.borgbackup`) | continuity with the previous setup: same tool, same repositories; declarative on NixOS |
| B. restic (through the NixOS module) | similar model, many storage backends, single binary, no SSH service needed on the target |
| C. Backrest (a web UI over restic) | adds scheduling, a UI and restore browsing |
| D. Kopia | snapshots with a UI and policies, encryption by default |

Layer 2, databases (tier 1). I prefer continuous WAL archiving with `archive_command` plus scheduled base backups, in a Barman-compatible way, and ideally a GUI to schedule the full backups. That is the standard shape of point-in-time recovery and is the main line to test.

| Option | What it is | GUI | Notes |
|---|---|---|---|
| E. pgBackRest | WAL archiving (`archive-push`), full, differential and incremental base backups, S3, SFTP, encryption | no | its maintenance crisis in 2026 is a known worry |
| F. WAL-G | WAL archiving and base backups to object storage | no | a single binary |
| G. Barman | WAL archiving or streaming, base backups, PITR | none of its own | scheduling through `barman cron` |
| H. Databasus | a web application that schedules logical and physical backups, with continuous WAL streaming for PITR to any second | yes, the point of it | one container, plus an agent; incremental physical backups need PostgreSQL 17 |
| I. Litestream (SQLite) | continuous replication of the Vaultwarden database | no | |
| J. Crash-consistent filesystem snapshots of the database dataset, every few minutes | no PostgreSQL-specific tool at all | no | the experiment below shows the snapshots are valid backups |

Layer 3, where the copies go ([ADR 0007](0007-offsite-copy.md)): the big local disk (it does not survive a fire or a theft); Proton Drive through the official CLI; object storage (S3-compatible: no user session, costs money per TB); a remote disk over SSH (cheap, needs a place and a person); a cold disk rotated by hand (no running cost, protects against ransomware, depends on discipline).

Because the storage is being reorganized anyway, snapshotting filesystems (ZFS, btrfs) become a fourth, orthogonal layer. They are not a replacement for an offsite, encrypted backup, and they change how disks are laid out and how much RAM the machine uses. [ADR 0005](0005-storage-layout-and-filesystem.md) measures them.

## Effect of P1 (clean over clever)

Whether a maintained NixOS module exists is the test ([principles](../principles.md)). What was found:

| Option | Module in nixpkgs | Verdict under P1 |
|---|---|---|
| Borg | `services.borgbackup`, and `services.borgmatic` | clean |
| restic | `services.restic.backups`, and `services.restic.server` | clean |
| Backrest | a package, no module | needs a hand-written service: counts against it |
| Kopia | a module is in review, not merged as far as found | set aside until merged |
| sanoid and syncoid, btrbk | `services.sanoid`, `services.syncoid`, `services.btrbk` | clean |
| PostgreSQL logical dumps | `services.postgresqlBackup` (pg_dump only, no PITR) | clean, weaker |
| PostgreSQL WAL streaming | `services.postgresqlWalReceiver` (pg_receivewal only: no base backups, no restore) | clean but incomplete |
| Litestream | a module exists | clean |
| pgBackRest | `services.pgbackrest` (repositories, stanzas, backup jobs as timers); a first search missed it | clean for a remote repository; about six lines of ours for a local one |
| WAL-G, Barman | packages only, no module found | each needs a hand-written service and scheduling |
| Databasus | not in nixpkgs; a container image | runs through `virtualisation.oci-containers`: tried, 13 lines, image pinned by digest |

With `services.pgbackrest` there is an end-to-end native path to point-in-time recovery on NixOS; WAL-G and Barman have none.

## Criteria, in this order, fixed before any test

1. Restore verified in the lab: time to restore files and a database from an empty machine, and whether the result is correct (checksums, a database that starts and answers). For tier 1, also whether a database can be restored to a chosen moment.
2. Data-loss window actually reached per tier (measured, not configured).
3. Custom glue (P1): lines of our own Nix and scripts, number of exceptions in the register, and what an upgrade of the tool would make us retest. This criterion came from my rule of no hybrid, crooked or manual solutions.
4. Failure modes: what a corrupted repository, a lost key, a half-finished run and a full disk do; how each is noticed.
5. Security: encryption of every copy, where the key lives, whether a compromised server can delete its own backups.
6. Fit with NixOS and the offsite path.
7. Effort and moving parts: setup time, tools to keep updated, how much of it is declarative.

## Experiments

### Point-in-time recovery: pgBackRest and Barman

`lab/experiments/pitr-bakeoff.sh`, in the NixOS lab VM (PostgreSQL 17, pgBackRest 2.58, Barman 3.14, repositories on a separate disk). A writer inserts one row at a time and records the last row PostgreSQL acknowledged, so a loss can be counted exactly. The scenario: a full backup while the writer runs; a moment T_good is noted; a table is dropped (the mistake); the writer goes on; the machine is crashed with `kill -9`. Then restore to T_good, and restore to the latest point. `archive_timeout` is 30 s.

| | pgBackRest (archive-push) | Barman (streaming) |
|---|---|---|
| Full backup under load | 15 s, 17 MB (compressed, encrypted AES-256) | 6 s, 121 MB (gzip; includes the WAL already streamed) |
| Restore to T_good | exact: the dropped table is back, the counter ends where T_good had it; 18 s | exact within one row; 3.4 s |
| Restore to the latest point, after a crash | 106 acknowledged commits lost out of 3410 (about 5 s of writes) | 158 lost out of 2566 (about 8 s of writes) |
| Our own configuration | 16 lines | 20 lines (plus manual steps) |
| Custom scripts | 0 | 0 |

Both tools lose the tail of the WAL that was not yet archived or completed when the machine died, bounded by `archive_timeout`. That window only matters when the primary's own disk is lost; if the machine crashes and the disk survives, PostgreSQL recovers by itself and nothing is lost. Barman documents a synchronous mode for zero loss; the attempt in the lab was not conclusive and no number is claimed for it.

Things the experiment exposed, each one a cost of the tool:

- pgBackRest: the time given to `--type=time` accepts milliseconds but not microseconds, and no space before the time zone; the log directory must exist or every command warns. It does not stream WAL: the loss window is the archive interval.
- Barman: it does not create its own system user; `barman cron` must run every minute (a timer to write); until one WAL segment arrives `barman check` fails and a backup refuses to start, so a manual `barman switch-wal` is the first step; and its background receiver must be supervised like a service.
- Both: the scheduling (a full backup weekly, incremental or differential more often) is a systemd timer each, in our own Nix, and not in the 16 or 20 lines.

### Databasus, with its web UI

Tried in the lab (v3.60.0, container image pinned by digest, driven with a headless Chrome; pictures in [docs/evidence/databasus/](../evidence/databasus/)). For a database the server can reach directly, no agent is needed: Databasus opens a physical replication slot and a walsender of its own and streams the WAL from its container, and `archive_command` stays empty.

| | Databasus (direct connection, web UI) |
|---|---|
| Setup | about a dozen UI steps. It checks prerequisites and tells you the command (`summarize_wal = on` was missing), offers a replication-only user, and took a first full backup and started streaming by itself ([picture](../evidence/databasus/01-backup-configuration.png)) |
| Full backup while the writer runs / incremental | under a second, 3.3 MB / under a second, 0.06 MB (needs PostgreSQL 17 with `summarize_wal`) |
| Restore to T_good | correct to the second (the UI picks seconds, not milliseconds); prepared in 4.5 s plus 1.7 s to start ([picture](../evidence/databasus/03-restore-dialog.png)) |
| Restore to the latest point, after a crash | 206 acknowledged commits lost out of 4728, in line with the others |
| Our own configuration | PostgreSQL: 6 lines; NixOS: 13 lines to declare the container, its volume and the firewall rule it needs. Custom scripts: 0 |
| Declared as code | the container is; its configuration is not: the first account, the schedules and the retention live in its own database, and the web application has no API documentation |

What the lab showed about running it:

- A restore is a generated command to run by hand on the restore host (`curl … | sh` with a one-time token, which needs `zstd` and the PostgreSQL 17 client tools, into an empty directory). Nothing is installed on the database server for it, but it is a manual step that depends on the Databasus server being up.
- Recreating the container keeps everything: a version bump is a new digest and a restart.
- Its own state is a dependency that must be backed up: an embedded PostgreSQL, the backups of a "local" storage, and `secret.key`. With the key removed the container started as "healthy", generated a different key without saying so, and from that moment could not use the stored credentials: the database showed Unavailable ([picture](../evidence/databasus/04-lost-key-unavailable.png)) and WAL streaming stopped, with no error in the container log. Putting the original key back made it resume. A container's "healthy" says nothing about backup health; a notifier must be configured. This is also a custody point for [ADR 0003](0003-secrets.md).
- Not tested: PostgreSQL 14 (the UI offers only full backups there), an encrypted restore on a fresh instance, and restoring Databasus itself from nothing.

The price of a GUI: a schedule set in a web interface lives in that application's own database, not in the flake. After a rebuild from an empty machine the schedule is whatever the restored state says, and nothing in the repository says what it should be. That is a manual step and an invisible piece of configuration, which is what P1 is against. It can be made acceptable (the application's state is a volume that is backed up and restored, and the drill proves it), but the tools without a UI express the same schedule as a NixOS timer, in code.

### Filesystem snapshots

`lab/experiments/pg-snapshot-check.sh`, in the NixOS lab VM on ZFS and btrfs: PostgreSQL running pgbench and a counter writer, five snapshots taken at random moments while it was writing, each restored and started. All ten recovered: the pgbench invariant held and the counter had no gaps, in about 2 seconds on ZFS and 11 on btrfs. The negative control (a plain `cp` of the files of the running cluster) broke 6 of 6 times. So the check can tell a good backup from a bad one. Snapshots give recovery points as often as the interval, with nothing PostgreSQL-specific to maintain. They do not give recovery to an arbitrary second, which is what WAL archiving is for.

### Round 2: PostgreSQL 14, sync, and object storage

The same scenario on PostgreSQL 14 (the version Immich's database was on), with Garage as a local S3 endpoint. The first runs failed for both tools in the same way, because of the scenario: the target time could fall after the last archived segment, and PostgreSQL refuses that. The script now waits until the WAL up to the target is archived before the mistake is made.

| Combination | Full backup under load | Restore to the moment before the mistake | Commits lost at the latest point | Lines of our configuration | What it cost beyond that |
|---|---|---|---|---|---|
| pgBackRest, local disk | 13.5 s, 17 MB (zstd, encrypted) | OK, 15 s | 3 | 16 | nothing: `restore` writes the recovery settings itself |
| Barman (server, streaming), local disk | 6.1 s, 126 MB | OK, 2.5 s | 43 | 20 | a declared system user, `barman cron` every minute, a first `switch-wal`, its own catalog |
| pgBackRest, S3 repository | 4.2 s, 12 MB | OK, 15.6 s | 47 | 24 (the S3 keys are part of it) | none for a real S3; in the lab a TLS proxy was needed because Garage speaks plain HTTP |
| Barman Cloud, S3 | 6.0 s, 222 MB | OK, 5.7 s | 65 | 16, of which 3 are written by hand at restore time | `barman-cloud-restore` only fetches the base backup: `restore_command`, the target and `recovery.signal` are written by hand; a test restore must run with `archive_mode = off`, or it archives a new timeline into the same bucket and a later "latest" restore silently stops at the old target |
| Barman, synchronous | writes about a third slower | OK, 2.4 s | 1,142 with `barman recover`; 0 when the `.partial` segment is copied in by hand | 1 more line | the synchronous receiver starts only if `synchronous_standby_names` is set before it starts, and zero loss needs a manual copy in the disaster path |
| Databasus, direct connection | not measured | not available: physical incremental and WAL streaming need PostgreSQL 17 ([picture](../evidence/databasus/05-pg14-full-backups-only.png), [picture](../evidence/databasus/06-pg14-incremental-blocked.png)) | recovery only to the time of a full backup | n/a | the same costs as before |
| Databasus, with its agent | not tested | not available | not available | n/a | its documentation says the agent is deprecated and needs PostgreSQL 15 or newer; it would also be a binary fetched with `curl` and started by hand, which P1 does not allow |

The losses are all of the same order and bounded by `archive_timeout` and by where the last segment happened to end; 3 against 65 is not a ranking, and the sizes are not comparable either.

- pgBackRest is the cleanest: one configuration file, the restore command does everything, compression and encryption are built in, S3 and a local disk are the same tool with another repository line, and it can write to several repositories at once.
- Barman restores fastest and is the most mature for a standby on another machine, but needs the most set-up. Its synchronous mode is real, but only with a manual step at recovery time.
- Barman Cloud is simple to start and needs no catalog host, but the restore is not one command, and the timeline pitfall is easy to fall into.
- Databasus cannot deliver point-in-time recovery on PostgreSQL 14 at all. It becomes a candidate only if the database moves to 17.

On the S3 endpoint itself: MinIO is flagged insecure in nixpkgs (the project is no longer maintained). Garage has a NixOS module and worked, but its cluster layout, bucket and key are created with imperative commands, which only matters if S3 is self-hosted. A local Garage next to the server is not an offsite copy.

### Round 3: the real Immich database

On the real Immich schema (PostgreSQL 17, native, pgBackRest through its module): a full backup of 167.5 MB into 53.3 MB; a point-in-time restore after deleting six assets brought the rows back in 4 s; the six original files did not come back, because Immich deletes them with the rows. The database restore and the files must go back to the same moment.

## Decision

Databases: pgBackRest, through its NixOS module, with the schedule in code (systemd timers) and point-in-time recovery. `archive_timeout` is 30 s: I accept up to 30 seconds of loss and pursue nothing tighter. It beat the others on my criteria (clean, plug and play, updates without glue around them):

| Why pgBackRest | What it cost in the lab |
|---|---|
| a NixOS module that declares repositories, backup jobs as timers, and sets `archive_command` itself; one configuration file; one command restores (recovery settings written by the tool); compression and encryption built in; writes to S3 or SFTP natively | about six lines of our own for a local repository, two of them overriding the module's units ([ADR 0006](0006-postgresql-version-and-immich.md)); a first backup job must run once before archiving works |

Not chosen:

- Barman and Barman Cloud: no NixOS module (every unit, user and timer is ours to write), a separate catalog, and for Barman Cloud a restore that only fetches the base backup. Synchronous mode gives zero loss only with a manual copy in the disaster path, and I do not need zero.
- Databasus: no point-in-time recovery below PostgreSQL 17, the configuration lives in its own database, the restore key must be kept outside its volume, and its agent is deprecated. The GUI was not decisive.
- Filesystem snapshots as the backup: not point-in-time, and I dropped scheduled snapshots altogether (below). The restore of the files to the same moment as the database is done from Borg.

The files of the services. No periodic ZFS snapshots, and no replication of snapshots. What a snapshot would undo (a deleted or overwritten file) is already in the Borg repositories for anything older than the Borg interval, and a snapshot costs space for the blocks it keeps and complicates the pool; the only gap is a file created and destroyed within one or two hours.

- Borg every one to two hours reads the files as they are, into two repositories:
  - an offsite repository on the mid-size disk: only the selected family data; it is the one mirrored to Proton Drive or pushed to another provider ([ADR 0007](0007-offsite-copy.md));
  - a repository of everything on the large disk: all service data, the NAS share and the configuration; not the databases (pgBackRest covers them), not the media (a plain copy), not the Time Machine partition, not the VM disks (replaceable). Without it, everything outside the selection and outside pgBackRest would be in no repository at all.
- Reading live files is acceptable without a snapshot because the databases are in PostgreSQL (every service that can use PostgreSQL moves to it: Immich already, Nextcloud from MariaDB, Vaultwarden from SQLite), so no SQLite or MariaDB file has to be copied while it is open. What remains is files that are rebuildable or change rarely: Syncthing's index, Jellyfin's stores (users and watch state: an inconvenience to lose, not a loss) and the photos. A file that changes during a Borg run is reported as a warning and picked up by the next run. If a consistent source is wanted later, one snapshot-creating block can be added in code.
- The database is backed up by pgBackRest and restored to a moment matching a Borg archive.
- Media: a plain copy on the large disk, not Borg: written once, incompressible, nothing personal, and the copy can be mounted directly if the media disk dies.

A restore drill must bring back both the database and the files, because a database restored without the files left six originals missing in the lab.

How Borg is run (measured in the lab): through the NixOS module `services.borgbackup.jobs.<name>`, which writes the job's script itself and installs a timer. It initializes the repository if it is missing (`doInit`), creates the archive, prunes by the declared retention and compacts, with the passphrase read from a file (`passCommand`, a sops secret in production), `failOnWarnings = false` (a file that changes during the read is a warning, not a failure), and `startAt` for the schedule. Two jobs are about a dozen lines each and no script of ours. In the lab three runs in one day left one archive per day and a restore of the latest archive was identical to the source. `services.borgmatic` was also tried: it adds consistency checks and monitoring hooks, but it does not create the repository (a manual `borgmatic repo-create`), which is a manual step under P1. So the plain module is the choice.

What the module does not do, and is left to later phases: a periodic `borg check`, a verification restore, and a notification when a job fails (phase 5 and the restore drill of phase 7). For a `repokey` repository the key is inside the repository: export it (`borg key export`) and keep it with the passphrase, off the machine, or a damaged repository configuration loses the backup.

Retention: a few weeks, not six months: pgBackRest weekly full and daily differential (two full backups kept). For Borg I wanted hourly archives for the last two or three days, so the rule is `within 3d`, `daily 11`, `weekly 4`, no monthly. The 14 days are what a pgBackRest point-in-time restore can reach (two weekly full backups kept, so 7 to 14 days), which keeps the two coherent: a database restored to any moment in its window finds files from the same day, and from the same hour in the last 3 days. (`keep-daily 7` alone kept one archive a day and no hourly ones.)

Rule sets tried on 192 archives (120 hourly for the last 5 days, then two a day up to 40 days), with `borg prune --dry-run`:

| Rule set | Kept | Every hour kept back to | At least one a day for | Oldest kept |
|---|---|---|---|---|
| R0, the old one: `daily 7, weekly 4` | 11 | none | 7 days | 33 days |
| R1: `within 3d, daily 7, weekly 4` | 83 | 3 days | 10 days (the 7 daily days come after the 3) | 33 days |
| R2 (chosen): `within 3d, daily 11, weekly 4` | 87 | 3 days | 14 days, as long as the database's window | 40 days |
| R3: `within 3d, daily 11, weekly 3` | 86 | 3 days | 14 days | 33 days |
| R4: `hourly 72, daily 11, weekly 4` | 87 | 3 days | 14 days | 40 days |

R2 and R4 keep the same archives; R2 is chosen because `within` states the intent (the last 3 days, whatever the cadence) and does not depend on the jobs running exactly every hour. Not measured: the cost of the archive check with 87 archives of a real library.

Offsite: [ADR 0007](0007-offsite-copy.md). Disks and filesystem: [ADR 0005](0005-storage-layout-and-filesystem.md). The full drill planned for phase 7 ran and passed in the lab ([ADR 0014](0014-automation-and-restore-drill.md)).

Revisit if the local-repository overrides turn out to break on a module update (the restore drill is what would show it), or if a stricter loss limit is wanted.
