# 0004. Backups: the tool and the restore drill

- **Status:** proposed (draft: requirements and criteria to be confirmed by the owner **before** any experiment)
- **Date:** 2026-09-29
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

## Options to consider

| Option | Why it is a contender |
|---|---|
| A. BorgBackup through the NixOS module (`services.borgbackup`) | continuity with v0: same tool, same repositories, same habits; declarative on NixOS |
| B. restic (through the NixOS module) | similar model, many storage backends, simple single binary; no need for SSH access on the target |
| C. Backrest (a web UI over restic) | named in the v0 re-engineering notes; adds scheduling, a UI and restore browsing |
| D. Kopia | snapshots with a UI and policies, encryption by default |

The offsite destination is part of each option: v0 mirrors to Proton Drive with the official CLI, which needs the user session. Whether that survives on NixOS is gate G3 of [ADR 0002](0002-host-as-code.md)
(the Proton Pass CLI already runs with nix-ld; the Drive CLI is untested).

## Proposed criteria, in this order (confirm or change before testing)

1. **Restore verified in the lab**: time to restore files and a database from an empty machine, and whether the result is correct (checksums, a database that starts and answers).
2. **Failure modes:** what a corrupted repository, a lost key, a half-finished run and a full disk do; how each is noticed.
3. **Security:** encryption of every copy, where the key lives, whether a compromised server can delete its own backups (append-only or a pull model).
4. **Fit with NixOS and the offsite path** (Proton Drive or another target).
5. **Effort and moving parts:** setup time, tools to keep updated, how much of it is declarative.

## Scenario every option must run (the equivalent of the host spec)

A lab VM with a Postgres database, a directory of files with known checksums and an SQLite file; a backup; then the VM is destroyed, a new empty one is built from the flake, and only the backup copy
and the key are given to it. Measured: backup time and size, time to restore, and whether every file and every row came back. Then the negative cases: wrong key, a damaged repository, a deleted archive.

## Open questions for the owner

- Is the media library (`/mnt/nas2/media`) part of what must survive, or only the family's data (photos, documents, passwords)?
- What is the acceptable data-loss window (v0: up to 24 hours, one run per night)?
- Is the offsite copy still Proton Drive, or is another destination acceptable if it is easier to automate?

## Decision

_Pending: nothing has been tested._
