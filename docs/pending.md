# Pending items

Things deliberately postponed, so they are not lost. Each has an owner decision or a gate behind it. Updated 2026-10-01.

## Waiting for the owner

| Item | Why it waits | Blocks |
|---|---|---|
| **Buy one SSD of about 500 GB** (chosen: option B with the owner's roles, [ADR 0005](decisions/0005-storage-layout-and-filesystem.md)); the second can follow later | the owner's money | the real layout |
| **Secure Boot** (signed boot chain with the TPM key tied to it), postponed by the owner but expected in the system | what it takes on NixOS is not yet looked at | making the TPM unlock mean something against a stolen machine |
| **Revisit what the backup disk holds** (replicas in clear, or only encrypted repositories and a plain media copy), which decides whether it needs encryption and whether snapshots are replicated at all | the owner asked why replicate and why not Borg: see the answer in the session and ADR 0004 | [ADR 0004](decisions/0004-backup.md), [0005](decisions/0005-storage-layout-and-filesystem.md) |
| (Only if Proton Drive fails its test) open the Hetzner Storage Box account and set its snapshot plan | a subscription and the console | the offsite copy if Proton Drive is not adopted ([ADR 0007](decisions/0007-offsite-copy.md)) |
| Create the private repository for the non-secret variables and write the age key down (Proton Pass and paper) | the owner's accounts | closing phase 1 |

## Waiting for the owner (application layer)

| Item | Why it waits | Blocks |
|---|---|---|
| New services to add next to the v0 ones (for example a replacement for Trakt) | application layer, not infrastructure | phase 4 |

## Gates and checks that need the real server or a maintenance window

| Item | What it needs |
|---|---|
| G2, hardware transcoding with ffmpeg in a container | the server installed, a short maintenance window |
| G3b, the Proton Drive CLI keeping its login in the keyring of a real desktop session | a desktop session on the real machine |
| S1 health of the system SSD with `smartctl` (S1 ran without root; the v0 `smartcheck` log covers the two HDDs). The owner judges it not worth checking: lightly used and easy to replace | optional |

## Lab work still to do

| Item | Notes |
|---|---|
| The offsite layer against a **real provider** (Hetzner Storage Box or BorgBase over SSH, Backblaze B2 with object lock): real throughput, the first 200 GB upload, the provider's own append-only or no-delete key | lab results and prices are in [ADR 0007](decisions/0007-offsite-copy.md); needs an account, so after the owner chooses |
| **Proton Drive as the first offsite candidate**: a small container with the official CLI and a dedicated repository of our own, tested against the seven criteria of [ADR 0007](decisions/0007-offsite-copy.md) (headless login, unattended and loud on failure, updates, size, restore, deletion, first upload) | one or two phases from now, on NixOS; rclone's Proton backend is unusable; the CLI's help shows only a browser login |
| A restore drill that restores Borg data **from a Hetzner snapshot** (the read-only `/.zfs/snapshot` path), not only from the live repository | phase 7 |
| Containers against native NixOS modules for each service (Immich, Jellyfin, Nextcloud, Vaultwarden, and the rest): lines of configuration, update, restore | phase 4 |
| The real SSDs: sizes, TPM, LUKS and the ZFS mirror on the real machine (ADR 0005 is decided, its sizes are not) | after S1 |
| The PostgreSQL 14 → 17 move, rehearsed **on the server** in a second instance with the old database kept as the way back (the owner will not hand over a real dump; size, time and index rebuild stay unmeasured until then) | phase 4, [ADR 0006](decisions/0006-postgresql-version-and-immich.md) |
| The root `README.md` still describes v0 | rewrite when the first phase closes |
| A restore drill that brings back the database **and the files to the same moment** | ADR 0006: a database restore alone left six originals missing |
| The pgBackRest overrides for a local repository (two units, the repository's mode, `ReadWritePaths`) re-checked after every module update | the restore drill of phase 7 |

## Housekeeping

- The old repository `nas-scripts-history` was deleted by the owner (2026-09-30).
