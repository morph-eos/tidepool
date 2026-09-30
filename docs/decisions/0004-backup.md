# 0004. Backups: the tool and the restore drill

- **Status:** proposed (requirements confirmed by the owner on 2026-09-30; criteria still to be confirmed **before** any experiment)
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

**Alternatives with a GUI** (searched 2026-09-30, [Sliplane](https://sliplane.io/blog/5-awesome-databasus-alternatives), [Bytebase](https://www.bytebase.com/blog/top-open-source-postgres-backup-solution/)):
Databasus is, in practice, the only open-source tool that combines a web UI with full/incremental physical backups and WAL streaming. The others with a UI are logical only (pgbackweb, pg_dump based);
Bacula and Bareos have web UIs and PostgreSQL plugins but are heavy general-purpose systems. **Barman, WAL-G, pghoard and pgmoneta have no UI.**

**The price of a GUI.** A schedule set in a web interface lives in that application's own database, not in the flake. After a rebuild from an empty machine the schedule is whatever the restored state says; nothing in the repository
says what it should be. That is a manual step and an invisible piece of configuration, which is what P1 is against. It can be made acceptable (the application's state is a volume that is backed up and restored, and the drill proves it),
but the tools without a UI express the same schedule as a NixOS timer, in code. The owner prefers a GUI for scheduling the full backups; this is the cost of that preference, to weigh in the decision.

**An experiment on J** (`lab/pg-snapshot-check.sh`, run in the NixOS lab VM on ZFS and btrfs): PostgreSQL 16 running pgbench and a counter writer, five snapshots taken at random moments **while it was writing**,
each restored and started. **All ten recovered**: the pgbench invariant held and the counter had no gaps, recovery took about 2 seconds on ZFS and 11 on btrfs. The **negative control** (plain `cp` of the files of the running cluster,
which is not a valid backup) broke **6 of 6** times: the cluster did not start. So the check can tell a good backup from a bad one. What J gives: recovery points as often as the snapshot interval (minutes), no GUI, nothing PostgreSQL-specific to maintain.
What it does not give: recovery to an arbitrary second, which is what WAL archiving (E to H) is for.

**Layer 3: where the copies go**

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
| Databasus | not found in nixpkgs; it is a container image plus an agent | would run through `virtualisation.oci-containers` (a native module); the agent is the open question |

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

## Still open

- ~~Are the criteria right?~~ Confirmed by the owner on 2026-09-30, with one addition: **no hybrid, crooked or manual solutions**, which became P1 and the third criterion.
- ~~For tier 1, is recovery to an arbitrary second a requirement?~~ Answered 2026-09-30: recovery to minutes or hours is the floor, and **the more precise the better, at equal cleanliness and ease of maintenance**. So point-in-time recovery (E to H) is wanted as a strong *should*, and snapshots (J) stay as the baseline and for what is not PostgreSQL.
- Containers are accepted for tools without a module (see [P1](../principles.md)); the owner prefers them where nothing native fits.

Settled on 2026-09-30: the media library **does not go offsite** (the disk would be too large and too costly); the **filesystem experiment was wanted and is done**
([ADR 0005](0005-storage-layout-and-filesystem.md)), and the backup tool is chosen after it.

## Decision

_Pending: nothing has been tested._
