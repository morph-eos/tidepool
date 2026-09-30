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
| 1 | Databases: Immich (Postgres), Nextcloud (Postgres after the planned move from MariaDB) | minutes, through point-in-time recovery | WAL archiving plus periodic base backups, with restore to a chosen moment |
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

| Option | Why it is a contender |
|---|---|
| E. pgBackRest | the established tool for Postgres WAL archiving and PITR; the v0 notes mention its maintenance crisis in 2026 |
| F. WAL-G | WAL archiving to object storage, a single binary |
| G. Barman | PITR with a separate backup server model |
| H. Databasus | named in the v0 notes: PITR with automatic restore verification; newer |
| I. Litestream (SQLite) | continuous replication of the Vaultwarden database |

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

## Proposed criteria, in this order (confirm or change before testing)

1. **Restore verified in the lab**: time to restore files and a database from an empty machine, and whether the result is correct (checksums, a database that starts and answers). For tier 1, also whether a database can be restored **to a chosen moment**.
2. **Data-loss window actually reached** per tier (measured, not configured): the gap between the last change and the last restorable state.
3. **Failure modes:** what a corrupted repository, a lost key, a half-finished run and a full disk do; how each is noticed.
4. **Security:** encryption of every copy, where the key lives, whether a compromised server can delete its own backups (append-only or a pull model).
5. **Fit with NixOS and the offsite path** (Proton Drive or another target).
6. **Effort and moving parts:** setup time, tools to keep updated, how much of it is declarative.

## Scenario every option must run (the equivalent of the host spec)

A lab VM with a Postgres database, a directory of files with known checksums and an SQLite file; a backup; then the VM is destroyed, a new empty one is built from the flake, and only the backup copy
and the key are given to it. Measured: backup time and size, time to restore, and whether every file and every row came back. Then the negative cases: wrong key, a damaged repository, a deleted archive.

## Still open

- Are the **criteria above** right, and in this order? (The owner has confirmed the requirements, not yet the criteria.)
- Does the **media library** go offsite as well, or only to the big local disk? It changes the cost of the offsite destination by an order of magnitude.
- Is a **short experiment on ZFS and btrfs** welcome before the disk layout is fixed, given that a third disk is coming?

## Decision

_Pending: nothing has been tested._
