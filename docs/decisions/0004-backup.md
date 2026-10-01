# 0004. Backups: the tool and the restore drill

- **Status:** accepted (2026-10-01): pgBackRest through its NixOS module; snapshots every 15 minutes kept short, and Borg every one to two hours from a snapshot for the files (no replication of snapshots); retention of a few weeks
- **Date:** 2026-09-29, updated 2026-09-30
- **Phase:** 2, Backup

## Context

In v0 there are two independent Borg repositories: `offsite` (encrypted, mirrored to Proton Drive with the official CLI) and a local one of all of `/mnt/nas2`, which is **not encrypted and holds `docker/.env`**.
Databases are dumped before Borg runs (Postgres for Immich, MariaDB for Nextcloud) and SQLite is snapshotted. What the README lists as **not covered**: Incus VM disks, `/etc`, the phone backups, the Syncthing identity,
and the bulk of `/mnt/nas`. No restore was ever rehearsed on a blank machine. The rule of this project is *backups come before data*: nothing holds real data until a restore has been rehearsed.

## Requirements

- **Must:** a restore, done in the lab from an empty machine and a copy of the backup only, that brings back files **and** databases and is verified (not "the command ended"); encryption at rest for every copy, offsite included;
  no secret in clear text in any backup; the key or passphrase kept outside the server ([ADR 0003](0003-secrets.md)); a failed backup is noticed (mail or notification), and so is a backup that did not run.
- **Should:** consistent database backups (a dump or a snapshot, never a copy of a live data directory); a way to know a backup is restorable without a full drill each time (a periodic verification); offsite copy that survives the loss of the house;
  retention like v0's (7 daily, 4 weekly, 6 monthly); the host configuration is already in Git, so `/etc` needs no backup.
- **Won't:** backing up the media library the same way as the family's data if it is not worth the space (to be decided per dataset), and a backup server that needs its own care.

## The owner's answers (2026-09-30)

- **What must survive:** the family's data for sure, **and the media library too**. The plan is to reorganize the storage: a **third disk** holds the media library, and the current large disk
  becomes the **backup target for everything, library included**. So the backup design and the disk layout are one decision, not two (see "A question this opens" below).
- **How much data may be lost:** **almost none for some services, where possible** (Postgres with properly configured WAL archiving), **a few hours where that is intelligent and sensible**.
  This replaces v0's single rule of "up to 24 hours" with tiers.
- **Offsite destination:** **not decided, wants a comparison**. Proton Drive stays a candidate, not a given.

### The tiers this implies

| Tier | What | Target window | How it is reached |
|---|---|---|---|
| 1 | Databases: Immich (Postgres), Nextcloud (Postgres after the planned move from MariaDB) | minutes, through point-in-time recovery | WAL archiving plus periodic base backups with restore to a chosen moment, **or** crash-consistent snapshots every few minutes (see layer 2, option J) |
| 1 | Vaultwarden (SQLite) | minutes | continuous replication of the SQLite file, or frequent consistent snapshots |
| 2 | Family files: photos, documents, Nextcloud data, configuration | a few hours | incremental, encrypted snapshots several times a day |
| 3 | Media library | a day or more is fine | scheduled to the big local disk; whether it goes offsite is open |

## Options to consider

The question splits into three layers, each with its own candidates. The layers can be chosen independently, and each gets the same kind of scenario.

**Layer 1: files (tier 2 and 3)**

| Option | Why it is a contender |
|---|---|
| A. BorgBackup through the NixOS module (`services.borgbackup`) | continuity with v0: same tool, same repositories, same habits; declarative on NixOS |
| B. restic (through the NixOS module) | similar model, many storage backends, single binary, no SSH service needed on the target |
| C. Backrest (a web UI over restic) | named in the v0 re-engineering notes; adds scheduling, a UI and restore browsing |
| D. Kopia | snapshots with a UI and policies, encryption by default |

**Layer 2: databases (tier 1)**

The owner's preference (2026-09-30): continuous WAL archiving with `archive_command` plus scheduled base backups, in a Barman-compatible way, and ideally a **GUI to schedule the full backups**, since the incrementals and the WAL
are handled by the archive command and the tool. That is the standard shape of point-in-time recovery, and it is taken as the main line to test.

| Option | What it is | GUI | Notes |
|---|---|---|---|
| E. pgBackRest | WAL archiving (`archive-push`), full/differential/incremental base backups, S3/SFTP/encryption | no | the v0 notes mention its maintenance crisis in 2026 |
| F. WAL-G | WAL archiving and base backups to object storage | no | a single binary |
| G. Barman | WAL archiving (`barman-wal-archive`) or streaming, base backups, PITR | **none of its own** (monitoring through EDB's commercial PEM) | scheduling through `barman cron` and cron jobs |
| H. Databasus | a web application that schedules logical and physical backups; physical backups use `pg_basebackup` and continuous WAL streaming (`pg_receivewal`) for PITR to any second | **yes**, the point of it | one Docker container, plus an agent next to the database; incremental physical backups need **PostgreSQL 17**, and v0's Immich database is **14** |
| I. Litestream (SQLite) | continuous replication of the Vaultwarden database | no | |
| J. **Crash-consistent filesystem snapshots** of the database dataset, every few minutes (sanoid or btrbk, replicated to the large disk) | no PostgreSQL-specific tool at all | no | see the experiment below: the snapshots are valid backups |

**An experiment on E and G** (`lab/pitr-bakeoff.sh`, run in the NixOS lab VM with PostgreSQL 17.11, pgBackRest 2.58.0 and Barman 3.14.1, both from nixpkgs, repositories on a separate disk). A writer inserts one row at a time and records the last row
PostgreSQL acknowledged, so a loss can be counted exactly. The scenario: a full backup **while the writer runs**; a moment T_good is noted; a table is dropped (the mistake); the writer goes on; the machine is crashed with `kill -9`.
Then: restore to T_good, and restore to the latest point. `archive_timeout` is 30 s.

| | pgBackRest (archive-push) | Barman (streaming, `backup_method = postgres`) |
|---|---|---|
| Full backup under load | 15 s, 17 MB (compressed, **encrypted** AES-256 in the repository) | 6 s, 121 MB (gzip; includes the WAL already streamed) |
| **Restore to T_good** | **exact**: the dropped table is back and the counter ends at 2782 where T_good had 2782; 18 s | **exact within one row**: ends at 2001 where T_good had 2000; 3.4 s |
| **Restore to the latest point**, after a crash of the primary | 106 acknowledged commits lost out of 3410 (about 5 s of writes) | 158 lost out of 2566 (about 8 s of writes) |
| Our own configuration | 16 lines (repository, retention, encryption, compression, log path, and the `archive_command`) | 20 lines (plus the manual steps below) |
| Custom scripts | 0 | 0 |

How to read the losses: both tools lose the tail of the WAL that was **not yet archived or completed** when the machine died (bounded by `archive_timeout`; Barman's streaming keeps the current segment in a `.partial` file that `barman recover` does not use).
It is the window when the **primary's own disk is lost**. If the machine crashes and the disk survives, PostgreSQL recovers by itself and nothing is lost. Barman documents a **synchronous** mode (PostgreSQL waits for Barman to flush each commit) for zero loss;
the attempt in the lab **was not conclusive**: writes almost stopped (4 rows in two minutes) and the variant would need its receiver set up for synchronous flushing, so no number is claimed for it.

Things the experiment exposed, each one a cost of the tool:

- **pgBackRest:** the time given to `--type=time` accepts milliseconds but not microseconds, and **no space before the time zone** (`…47.049+02`, not `…47.049 +02`); the log directory must exist or every command warns. It does not stream WAL: the loss window is the archive interval.
- **Barman:** it does **not create its own system user** (one must be declared); `barman cron` must run **every minute** (a timer to write); until one WAL segment arrives `barman check` fails and a backup refuses to start, so a documented **manual `barman switch-wal` is the first step**;
  on a quiet database the backup waits for the end-of-backup segment, which needs `archive_timeout`; and an overlapping run in the lab showed its background receiver must be supervised like a service.
- **Both:** the scheduling (a full backup weekly, incremental or differential more often) is **not in the 16 or 20 lines**: it is a systemd timer each, in our own Nix.

**Alternatives with a GUI** (searched 2026-09-30, [Sliplane](https://sliplane.io/blog/5-awesome-databasus-alternatives), [Bytebase](https://www.bytebase.com/blog/top-open-source-postgres-backup-solution/)):
Databasus is, in practice, the only open-source tool that combines a web UI with full/incremental physical backups and WAL streaming. The others with a UI are logical only (pgbackweb, pg_dump based);
Bacula and Bareos have web UIs and PostgreSQL plugins but are heavy general-purpose systems. **Barman, WAL-G, pghoard and pgmoneta have no UI.**

**Databasus, tried in the lab with its web UI** (v3.60.0, container image pinned by digest, 1.13 GB; driven with a headless Chrome and screenshots, scripts in branch `exp/pitr-databasus`; the pictures are in
[docs/evidence/databasus/](../evidence/databasus/)). **This corrects what I had written after reading its documentation**, which said the agent is required: for a database the server can reach directly, **no agent is needed**.
Databasus opens a **physical replication slot** and a walsender of its own (`databasus_slot_…`, `databasus_wal_receiver_…`) and streams the WAL from its container. PostgreSQL's `archive_command` stayed empty.
The agent (a downloaded binary started by hand with a token) is for databases the server cannot reach.

| | Databasus (direct connection, web UI) |
|---|---|
| Setup | about a dozen UI steps: first account, workspace, a storage, the database (physical, full + incremental + WAL streaming), a connection test, schedule, retention, encryption, notifiers ([picture](../evidence/databasus/01-backup-configuration.png)). It **checks prerequisites and tells you the command** (`summarize_wal = on` was missing) and **offers a replication-only user**; it took a first full backup and started streaming by itself |
| Full backup while the writer runs | under a second, 3.3 MB (the UI shows whole seconds) |
| Incremental backup | under a second, 0.06 MB (needs PostgreSQL 17 with `summarize_wal`) |
| **Restore to T_good** | **correct to the second**: asked for 15:10:36 UTC, the dropped table is back (500,000 rows), the counter ends at 3756, its last row was committed at 15:10:35.981, no gaps. The UI picks seconds, not milliseconds. Prepared in 4.5 s plus 1.7 s to start ([picture](../evidence/databasus/03-restore-dialog.png)) |
| **Restore to the latest point**, after a crash | **206 acknowledged commits lost** out of 4728, in line with the other two: the WAL is archived in completed segments every 30 s, which is the `archive_timeout` set on PostgreSQL |
| Our own configuration | PostgreSQL: `wal_level`, `max_wal_senders`, `summarize_wal`, `archive_timeout` and two `pg_hba.conf` lines (6). NixOS: **13 lines** to declare the container, its volume and the firewall rule it needs to reach the host ([module](../../nixos/modules/databasus.nix) in the branch). Custom scripts: **0** |
| Declared as code | the **container is**; its **configuration is not**: the first account, the schedules and the retention live in its own database. The web application has **no API documentation** (`/openapi.json` returns the application's own page), so configuration as code would mean reverse-engineering the calls of its UI |

What the lab showed about running it:

- **A restore is a generated command to run by hand on the restore host**: `curl … | sh` with a one-time token, which needs `zstd` and the PostgreSQL 17 client tools, into an empty directory, and then `chown`, `pg_ctl start` and a wait for the replay.
  Nothing is installed on the database server for it, and the prompt is clear, but it is a manual step that depends on the Databasus server being up.
- **Recreating the container keeps everything** (session, database, backups): a version bump is a new digest and a restart. The same after a crash of PostgreSQL: it reconnected by itself.
- **Its own state is a dependency that must be backed up**: an embedded PostgreSQL, the backups of a "local" storage if that is what is used, and **`secret.key`**. With the key removed the container started as "healthy",
  **generated a different key without saying so, and from that moment could not use the stored credentials**: the database showed **Unavailable** ([picture](../evidence/databasus/04-lost-key-unavailable.png)) and **WAL streaming stopped, with no error in the container log**.
  Putting the original key back made it resume by itself. Its status as a container ("healthy") says nothing about backup health: a notifier ("backup failed", "WAL gap") must be configured to hear about it. This is also a custody point for [ADR 0003](0003-secrets.md).
- The supported storages are local, S3, Google Drive, NAS, Azure Blob, FTP, SFTP and Rclone, which keeps the offsite question open.
- **Not tested:** PostgreSQL 14 (Immich's database in v0; the UI offers the incremental mode only with 17), an encrypted restore on a fresh Databasus instance, and what it would take to restore *Databasus itself* from nothing.

**The price of a GUI.** A schedule set in a web interface lives in that application's own database, not in the flake. After a rebuild from an empty machine the schedule is whatever the restored state says; nothing in the repository
says what it should be. That is a manual step and an invisible piece of configuration, which is what P1 is against. It can be made acceptable (the application's state is a volume that is backed up and restored, and the drill proves it),
but the tools without a UI express the same schedule as a NixOS timer, in code. The owner prefers a GUI for scheduling the full backups; this is the cost of that preference, to weigh in the decision. The lab confirmed it: the configuration of Databasus is not in the flake, and losing its key or its volume loses the ability to use what it backed up.

**An experiment on J (snapshots)** (`lab/pg-snapshot-check.sh`, run in the NixOS lab VM on ZFS and btrfs): PostgreSQL 16 running pgbench and a counter writer, five snapshots taken at random moments **while it was writing**,
each restored and started. **All ten recovered**: the pgbench invariant held and the counter had no gaps, recovery took about 2 seconds on ZFS and 11 on btrfs. The **negative control** (plain `cp` of the files of the running cluster,
which is not a valid backup) broke **6 of 6** times: the cluster did not start. So the check can tell a good backup from a bad one. What J gives: recovery points as often as the snapshot interval (minutes), no GUI, nothing PostgreSQL-specific to maintain.
What it does not give: recovery to an arbitrary second, which is what WAL archiving (E to H) is for.

**Layer 3: where the copies go** (measured and priced in [ADR 0007](0007-offsite-copy.md))

| Destination | Notes |
|---|---|
| The big local disk | the obvious tier-3 target; it does not survive a fire or a theft |
| Proton Drive (official CLI) | v0's choice; needs the user session, and the keyring question of gate G3 is still open on NixOS |
| Object storage (S3-compatible: Backblaze B2, Wasabi, and similar) | no user session, easy to automate, costs money per TB; restic, Kopia and WAL-G speak it natively |
| A remote disk over SSH (a friend's, a second site) | cheap, needs a place and a person; Borg's natural model |
| A cold disk, rotated by hand | no running cost, protects against ransomware; depends on discipline |

**A question this opens: the filesystem.** Because the storage is being reorganized anyway, snapshotting filesystems (ZFS, btrfs) become a fourth, orthogonal layer: instant local snapshots and cheap `send`/`receive` replication
to the big disk. They are not a replacement for an offsite, encrypted backup, and they change how disks are laid out and how much RAM the machine uses. Worth a short experiment before the layout is fixed, not after.

## Effect of P1 (clean over clever), 2026-09-30

Whether a maintained NixOS module exists is the test ([principles](../principles.md)). What was found (searches of nixpkgs and the NixOS option indexes, not exhaustive):

| Option | Module in nixpkgs | Verdict under P1 |
|---|---|---|
| Borg | `services.borgbackup`, and `services.borgmatic` | clean |
| restic | `services.restic.backups`, and `services.restic.server` | clean |
| Backrest | a package, **no module** (a forum thread shows problems with a hand-written service) | needs a hand-written service: cost counts against it |
| Kopia | a module is in review (nixpkgs PR 494870), not merged as far as found | set aside until merged |
| sanoid and syncoid | `services.sanoid`, `services.syncoid` | clean |
| btrbk | `services.btrbk` | clean |
| PostgreSQL logical dumps | `services.postgresqlBackup` (pg_dump only, **no PITR**) | clean, weaker |
| PostgreSQL WAL streaming | `services.postgresqlWalReceiver` (pg_receivewal **only**: no base backups, no restore) | clean but incomplete |
| Litestream | a module exists | clean |
| pgBackRest, WAL-G, Barman | packages only, **no module** found (WAL-G: users report systemd sandbox problems) | each needs a hand-written service and scheduling |
| Databasus | not found in nixpkgs; a container image | runs through `virtualisation.oci-containers` (a native module): **tried, 13 lines**, image pinned by digest. The agent is not needed for a reachable database |

So **there is no end-to-end native path to point-in-time recovery on NixOS today**, and the options E to H all need *some* definition of our own. That is not an automatic rejection: a service written straight from the tool's documentation
(the standard `archive_command`, a timer for the full backup) is configuration, not a patch to the core. It is a **cost to measure**, and the bake-off below measures it.

## Proposed criteria, in this order (confirm or change before testing)

1. **Restore verified in the lab**: time to restore files and a database from an empty machine, and whether the result is correct (checksums, a database that starts and answers). For tier 1, also whether a database can be restored **to a chosen moment**.
2. **Data-loss window actually reached** per tier (measured, not configured): the gap between the last change and the last restorable state.
3. **Custom glue (P1):** lines of our own Nix and scripts, number of exceptions in the register, and what an upgrade of the tool would make us retest.
4. **Failure modes:** what a corrupted repository, a lost key, a half-finished run and a full disk do; how each is noticed.
5. **Security:** encryption of every copy, where the key lives, whether a compromised server can delete its own backups (append-only or a pull model).
6. **Fit with NixOS and the offsite path** (Proton Drive or another target).
7. **Effort and moving parts:** setup time, tools to keep updated, how much of it is declarative.

## Scenario every option must run (the equivalent of the host spec)

A lab VM with a Postgres database, a directory of files with known checksums and an SQLite file; a backup; then the VM is destroyed, a new empty one is built from the flake, and only the backup copy
and the key are given to it. Measured: backup time and size, time to restore, and whether every file and every row came back. Then the negative cases: wrong key, a damaged repository, a deleted archive.

## Round 2 (2026-09-30): PostgreSQL 14, sync, and object storage

The owner's answers after round 1: stay on **PostgreSQL 14** (Immich's version) for now; minutes to a few hours of loss are acceptable, *closer to a point in time is better*; a GUI is **not decisive**, what counts is that the integration works out of the box and survives updates without glue around it;
Databasus must be judged **with and without its agent**; Barman Cloud and object storage are to be tried as well, because Barman's local-disk model is heavier (its own catalog and versions).
Everything below ran in the NixOS lab VM (`exp/pitr-pg14`, `lab/pitr-bakeoff.sh`, PostgreSQL 14.24, pgBackRest 2.58.0, Barman 3.14.1, Garage as a local S3 endpoint), with the same scenario as round 1: a full backup under load, `archive_timeout` 30 s, a dropped table, a `kill -9`, a restore to the moment before the mistake, and a restore to the latest point.

### A correction to the test itself

The first PostgreSQL 14 runs failed for **both** tools in the same way. The cause was the scenario, not the tools: the target time could fall after the last archived segment, and PostgreSQL refuses that (`recovery ended before configured recovery target was reached`). It had passed on 17 by luck of timing.
The script now waits until the WAL up to the target is archived before the mistake is made. The PostgreSQL 17 numbers of round 1 still hold (re-run: pgBackRest 25 and Barman 44 acknowledged commits lost; 14: 3 and 43).

### Results (PostgreSQL 14, one sequential writer, about 6,000 commits in the run)

| Combination | Full backup under load | Restore to the moment before the mistake | Restore to the latest point: commits lost | Lines of our configuration | What it cost beyond that |
|---|---|---|---|---|---|
| **pgBackRest, local disk** | 13.5 s, 17 MB (zstd, encrypted) | **OK**, 15 s | 3 | 16 | nothing: `restore` writes the recovery settings itself |
| **Barman (server, streaming), local disk** | 6.1 s, 126 MB (gzip) | **OK**, 2.5 s | 43 | 20 | a declared system user, `barman cron` every minute, a first `switch-wal`, its own catalog |
| **pgBackRest, S3 repository** | 4.2 s, 12 MB (zstd, encrypted) | **OK**, 15.6 s | 47 | 24 (the S3 keys are part of it) | none for a real S3 (TLS natively); in the lab a TLS proxy was needed because Garage speaks plain HTTP |
| **Barman Cloud, S3** | 6.0 s, 222 MB (no compression configured) | **OK**, 5.7 s | 65 | 16, **of which 3 are written by hand at restore time** | `barman-cloud-restore` **only fetches the base backup**: `restore_command`, the target and `recovery.signal` must be written by hand (`--target-time` does not do it); a test restore must run with `archive_mode = off`, or it archives a new timeline into the same bucket and a later "latest" restore silently stops at the old target (seen: 2,445 commits lost until fixed) |
| **Barman, synchronous** | writes about a third slower (one sequential writer: about 4,000 commits in the time async made 6,000) | OK (2.4 s) | **1,142 with `barman recover`**; **0 when the `.partial` segment is copied in by hand** (3,977 of 3,977) | 1 more line | the synchronous receiver starts only if `synchronous_standby_names` is set **before** the receiver starts (else `pg_receivewal` has no `--synchronous` and commits wait for a whole segment); `barman recover` ignores the `.partial` file, so zero loss needs **a manual copy in the disaster path** |
| **Databasus, direct connection** | not measured on 14 | **not available**: physical incremental and WAL streaming need PostgreSQL 17 (the UI offers "Full backups only" on 14 ([picture](../evidence/databasus/05-pg14-full-backups-only.png)), and blocks the other two modes asking for `summarize_wal`, a parameter that does not exist in 14 ([picture](../evidence/databasus/06-pg14-incremental-blocked.png))) | recovery only to the time of a full backup | n/a | the same costs as round 1 (state outside the code, a key to keep, a generated restore command) |
| **Databasus, with its agent** | not tested | not available | not available | n/a | Databasus's documentation says the agent is **deprecated** and needs **PostgreSQL 15 or newer**, so it cannot serve version 14; it would also be a binary fetched with `curl` and started by hand, which P1 does not allow |
| **Filesystem snapshots** (round 1, PostgreSQL 16 on ZFS and btrfs) | instant | 10 of 10 snapshots recovered | up to the snapshot interval | none | the only restore point is a snapshot |

How to read the losses: they are all of the same order and are bounded by `archive_timeout` and by where the last segment happened to end; 3 against 65 is not a ranking. The sizes are not comparable either (the compression differs).

### What this means, tool by tool

- **pgBackRest** is the cleanest: one configuration file, **the restore command does everything**, compression and encryption are built in, S3 and a local disk are the same tool with another repository line (**and it can write to several repositories at once**, a local one and an offsite one, natively).
  Its cost: it speaks TLS to S3 only; it does not protect a test restore from archiving into the real repository unless the path differs (it refused: `pg1-path` mismatch).
- **Barman** (server) restores fastest and is the most mature for a standby on another machine, but needs the most set-up: a catalog, a cron every minute and a first-WAL step. Its **synchronous** mode is real, and gives zero loss, but only with a manual step at recovery time.
- **Barman Cloud** is simple to start (two commands, no server) and it needs **no catalog host**, but the restore is **not one command**: the recovery settings are hand-written, and the timeline pitfall above is easy to fall into. As documented, that is not "plug and play".
- **Databasus** cannot deliver point-in-time recovery on PostgreSQL 14 at all. It becomes a candidate **only if Immich's database moves to PostgreSQL 17**, and its other costs stand.
- **Snapshots** stay as the base layer under any of them.

### The S3 endpoint itself

- **MinIO is flagged insecure in nixpkgs** (the project is no longer maintained) and was not used. **Garage** has a NixOS module and worked, but its cluster layout, bucket and key are created with **imperative commands** (`garage layout assign/apply`, `bucket create`, `key create`), which are not declarative. That only matters if S3 is self-hosted; a cloud bucket is created once in a web console.
- A local Garage next to the server is **not an offsite copy**: it would sit on the same machine. It only served as an endpoint for the test.

### What is still not tested

- PostgreSQL 14 **with Immich's vector extension** in the restore (to read from Immich's documentation and test).
- Databasus on 14 with logical (`pg_dump`) backups: it works by definition, but it is not point-in-time.
- The offsite layer itself (restic, Borg or Kopia to an S3 bucket or an SSH server, against Proton Drive): **the next round**. The v0 mirror to Proton Drive is a custom, Borg-aware script; under P1 that has to be replaced by something native or recorded as an exception.

## Round 3 (2026-09-30): what NixOS already provides, and the real Immich database

Searched and run in the lab ([ADR 0006](0006-postgresql-version-and-immich.md) has the details):

| Tool | NixOS module in 26.05 | What that means under P1 |
|---|---|---|
| pgBackRest | **yes**, `services.pgbackrest`: repositories and stanzas declared, **backup jobs as systemd timers**, `archive_command` set automatically | the schedule is in code; built for a repository on another host, and for a **local** one it needed about six lines of our own, two of them overriding the module (see ADR 0006) |
| Barman and Barman Cloud | **none** | the service, the timers, the system user and the `cron` are all ours to write and keep |
| `pg_receivewal` | yes, `services.postgresql-wal-receiver` | a stream of WAL, not a backup catalog |
| `pg_dump` | yes, `services.postgresql-backup` | a logical dump, not point-in-time |
| restic, Borg, borgmatic | yes (with timers) | the file-level layer, for the offsite copy |
| Databasus | none (a container, declared) | see round 1 and 2 |
| ZFS snapshots and replication | yes: `services.sanoid`, `syncoid`, `zrepl`; btrfs: `btrbk` | the snapshot layer |

On the **real Immich schema** (PostgreSQL 17, native, pgBackRest through its module): a full backup of 167.5 MB into 53.3 MB; a point-in-time restore after deleting six assets brought the rows back in 4 s; **the six original files did not come back**, because Immich deletes them with the rows. **The database restore and the files must go back to the same moment.**

## Still open

- ~~Are the criteria right?~~ Confirmed by the owner on 2026-09-30, with one addition: **no hybrid, crooked or manual solutions**, which became P1 and the third criterion.
- ~~For tier 1, is recovery to an arbitrary second a requirement?~~ Answered 2026-09-30: recovery to minutes or hours is the floor, and **the more precise the better, at equal cleanliness and ease of maintenance**. So point-in-time recovery (E to H) is wanted as a strong *should*, and snapshots (J) stay as the baseline and for what is not PostgreSQL.
- Containers are accepted for tools without a module (see [P1](../principles.md)); the owner prefers them where nothing native fits.

Settled on 2026-09-30: the media library **does not go offsite** (the disk would be too large and too costly); the **filesystem experiment was wanted and is done**
([ADR 0005](0005-storage-layout-and-filesystem.md)), and the backup tool is chosen after it.

## Decision (2026-10-01)

**Databases: pgBackRest, through its NixOS module**, with the schedule in code (systemd timers) and point-in-time recovery; `archive_timeout` **30 s** (the owner accepts up to 30 seconds of loss; nothing tighter is pursued).
Why it beat the others, in the order of the owner's criteria (clean, plug and play, updates without glue around them):

| Why pgBackRest | What it cost in the lab |
|---|---|
| a NixOS module that declares repositories, **backup jobs as timers**, and sets `archive_command` itself; one configuration file; **one command restores** (recovery settings written by the tool); compression and encryption built in; writes to S3 or SFTP natively, so the databases can go offsite on their own | about six lines of our own for a local repository, two of them overriding the module's units ([ADR 0006](0006-postgresql-version-and-immich.md)); a first backup job must run once before archiving works |

Not chosen, and why:
- **Barman and Barman Cloud:** no NixOS module (every unit, user and timer is ours to write), a separate catalog, and for Barman Cloud a restore that only fetches the base backup: the recovery settings are written by hand, and a test restore that archives into the same bucket silently truncates a later restore.
  Barman in synchronous mode gives zero loss only with a manual copy in the disaster path, and the owner does not need zero.
- **Databasus:** no point-in-time recovery below PostgreSQL 17, the configuration lives in its own database, the restore key must be kept outside its volume, and its agent is deprecated. The GUI was not decisive for the owner.
- **Snapshots of the filesystem alone:** not point-in-time; but they stay as the layer that restores **the files to the same moment** as the database ([ADR 0005](0005-storage-layout-and-filesystem.md)).

**The files of the services** (Immich's library, and the others), revised on 2026-10-01 with the owner (the replication of snapshots to another disk is **dropped**, because Borg does that job, encrypted and with history):
- **ZFS snapshots on the SSD every 15 minutes, kept short**: an undo button, and a consistent source for the file backup. Long history is Borg's job, not the snapshots'.
- **Borg every one to two hours, read from a snapshot** (never from live files), into a **repository prepared for the offsite on the 2 TB disk** (the owner's choice; it is what is mirrored to Proton Drive or pushed to Hetzner, [ADR 0007](0007-offsite-copy.md)).
- **Proposed, not yet confirmed:** the same job also writes a second repository of everything on the 16 TB disk, because the 2 TB disk is old and the owner asked for a backup of everything there.
- **The database** is not part of these file backups: pgBackRest is its backup; it is restored to a moment matching a Borg archive.
- **Media:** a plain copy on the 16 TB disk, not Borg (proposed; see the owner's open questions in [pending](../pending.md)).
A restore drill must bring back **both** the database and the files, because a database restored without the files left six originals missing in the lab.

**Retention:** a few weeks, not v0's six months: weekly full and daily differential with pgBackRest (two full backups kept), and the file backups as in [ADR 0007](0007-offsite-copy.md).

**Offsite:** [ADR 0007](0007-offsite-copy.md). **Disks and filesystem:** [ADR 0005](0005-storage-layout-and-filesystem.md).

Revisit if the local-repository overrides turn out to break on a module update (the restore drill of phase 7 is what would show it), or if a stricter loss limit is wanted.
