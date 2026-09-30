# 0006. PostgreSQL version, and how Immich's database runs

- **Status:** accepted (2026-10-01): PostgreSQL 17, native service, Immich in pinned containers; the 14 to 17 move rehearsed on the server with the old database kept as the way back
- **Date:** 2026-09-30
- **Phase:** 2, Backup (it decides what the backup tools have to cope with)

## Context

In v0 Immich's database runs in a container from `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`, which is also what Immich's own compose file still pins today. Two things make version 14 a poor base for the new system:

- **Point-in-time recovery is limited by the version.** [Databasus](0004-backup.md) offers physical incremental and WAL-streaming backups only from PostgreSQL 17, and its agent (deprecated) needs 15 or newer.
- **Support.** PostgreSQL 14 reaches the end of community support in November 2026.

The owner asked to try PostgreSQL 17 *with Immich* ("so we solve many problems"). What Immich's documentation says ([Pre-existing Postgres](https://docs.immich.app/administration/postgres-standalone/)): it is known to work with PostgreSQL `>= 14, < 20`, with **pgvector** `>= 0.7, < 0.9` and **VectorChord** `>= 0.3, < 2.0`; pgvecto.rs support was **dropped in Immich 3.0**.

## Requirements

- **Must:** Immich works on the chosen version, with its data migrated from v0's database; search by content (the vectors) keeps working; the database can be backed up and restored to a moment (ADR 0004).
- **Should:** no glue around a tool; secrets not in clear text or in the Nix store; updates that change a version and run the same checks.
- **Won't:** a custom-built PostgreSQL image.

## Options considered

| Option | Branch | Result in one line |
|---|---|---|
| A. The native NixOS module `services.immich` | `exp/immich-pg17` | **not usable**: nixos-26.05 marks `immich-2.7.5` insecure (no more 2.x updates, CVE-2026-59258; 3.x is only in the unstable channel) |
| B. Immich's containers, **and PostgreSQL 17 from Immich's image** (`17-vectorchord0.4.3-pgvectors0.3.0`) | `exp/immich-pg17` (`immich-lab.nix`) | works; the simplest move from v0 |
| C. Immich's containers, **and PostgreSQL 17 as the native NixOS service** (nixpkgs: VectorChord 1.1.1, pgvector 0.8.2), reached over its Unix socket | `exp/immich-pg17` (`immich-pgnative.nix`) | works; the database can then use the NixOS modules for backup |

All images are upstream's, pinned by digest (Immich v3.2.4, the latest release on 2026-09-28).

## Results

The lab instance was filled through Immich's API (an admin, 12 generated pictures, then more), with the machine-learning container computing the search vectors. The v0-equivalent state was measured on the **v0 image** (PostgreSQL 14.19, VectorChord 0.4.3, pgvector 0.8.1): 12 assets, 12 vectors, 24 thumbnails, a content search that finds all 12.

### Migration from PostgreSQL 14 to 17 (Immich's documented dump and restore)

| Step | Result |
|---|---|
| Dump from the running v0 container with the documented `pg_dump --clean --if-exists` | 18.8 MB (most of it the geodata Immich loads) |
| Restore into an empty PostgreSQL 17 with the documented `sed` of `search_path`, `--single-transaction`, `ON_ERROR_STOP=on` | exit 0, **A (image 17)** and **C (native 17, VectorChord 1.1.1)** |
| Immich 3.2.4 starts on the restored database, runs its migrations | yes, both |
| Login, 12 assets, 12 vectors, content search over all 12, thumbnail and original served | yes, both |
| A **new upload** after the move: thumbnail, machine-learning vector, found by search | yes, both |

Cost and caveats of the documented procedure:
- The restore needs a **`sed` on the dump** (Immich's own documented command). That is a line of glue in the restore path, not in steady state.
- **The server must not run during the restore** (it would create the schema first); on NixOS that means stopping its unit by hand.
- The documentation says nothing about changing major versions: the procedure that worked here is the normal dump and restore, which is a logical (not binary) copy, so it is independent of the version.

### pgBackRest on the native database (option C), with Immich's real schema

| | Result |
|---|---|
| Full backup | 167.5 MB of database into **53.3 MB** in the repository (zstd, encrypted), 18 s |
| Point-in-time restore | uploaded a picture, noted T_good, waited for the WAL, **deleted six assets for good through Immich's API**, stopped PostgreSQL and restored to T_good: **assets 7 → 13, restore plus start 4 s**, Immich back up, search finds the restored pictures |
| **What the restore does not bring back** | the **six original files**: Immich deletes the files on a permanent delete, so the rows came back and **the originals did not** (7 served, 6 missing). **A database restore must be paired with a restore of the files to the same moment**: the snapshot layer of ADR 0005 is what provides it |

### What the NixOS pgBackRest module needs (found while running it)

The module `services.pgbackrest` (repositories and stanzas declared; backup **jobs as systemd timers**; `archive_command` and `archive_mode` set automatically when `services.postgresql` is on) is the cleanest way to declare the schedule in code. It is built for a **repository on another host**. For a local repository on the same machine it needed:

| Finding | What it took |
|---|---|
| The module **refuses** `cipher-pass` and the S3 keys as options (they would land in the world-readable Nix store) | a file in pgBackRest's own `conf.d`, which in production is a **sops-nix template** (no glue, but it has to be written; in the lab a plain file) |
| The repository is the `pgbackrest` user's home, mode 0700; `archive-push` runs as `postgres` | `users.users.pgbackrest.homeMode = "770"` |
| pgBackRest always creates directories 0750 (it **ignores the umask**), and the module's jobs run as `pgbackrest`, so `postgres` cannot write where `pgbackrest` created the directories | the jobs run as `postgres` too: **two lines overriding the module's units** |
| `postgresql.service` is sandboxed (`ProtectSystem=strict`); `archive-push` runs inside it and got *Read-only file system* | `systemd.services.postgresql.serviceConfig.ReadWritePaths` |
| The stanza is created by the **first backup job**; until then `archive_command` fails and WAL piles up | the first job has to run once after the first start |
| With the repository at the default path, every one of these failed with errors that say *permission denied* or *WAL segment was not archived*, not what to change | nothing declarative fixes it: it is a documentation gap |

So the native module is clean for a remote repository and **needs about six lines of our own, two of which override the module** for a local one. Entered in [the exceptions register](../exceptions.md) if this option is chosen.

### Containers or native for the database itself

| | B. PostgreSQL 17 in Immich's image | C. PostgreSQL 17 native (NixOS) |
|---|---|---|
| Move from v0 | the same image family, one tag | a logical dump and restore (the same as B, from 14) |
| Extensions | shipped in the image (pinned) | from nixpkgs (VectorChord 1.1.1 is newer than the 0.4.3 of the image; accepted by Immich) |
| Backup tools | `archive_command` would run **inside** the container, where pgBackRest is not installed: only tools that connect from outside work (Barman streaming, Databasus, `pg_receivewal`) | **all of them**, including the pgBackRest module and its timers |
| Secrets | a password in the container environment | none: Unix socket and a peer rule (`identMap`), no password anywhere |
| Updates | a new digest to review | the channel, and a rebuild; a major version needs a dump and restore either way |
| Lines of our configuration | 5 for the container, plus a password it needs | 8 for the service, plus the six above if pgBackRest is added |

### Not tested

- **The real data.** The lab has a dozen generated pictures. A real library's database (hundreds of thousands of assets, real face and scene vectors, real vector indexes) must be rehearsed **privately** with a dump from the server: timings, size of the dump, index rebuild time. It cannot be done in the public repository.
- Whether v0's real database still holds **pgvecto.rs** data (its image ships both extensions); Immich 3 requires the move to VectorChord, which the documentation says is automatic when upgrading through 2.x.
- The other databases (Nextcloud's MariaDB, the SQLite files of Vaultwarden and Jellyfin): outside this decision.

## Criteria

1. **Immich works and v0's data can be carried over** (measured).
2. **The backup layer can reach point-in-time recovery** (ADR 0004).
3. **P1:** glue and overrides, secrets handling, what an update costs.
4. **Distance from what upstream runs and supports.**

## Decision (2026-10-01)

- **PostgreSQL 17**, as **option C: the native NixOS service**, with Immich's containers pinned by digest. It works with Immich 3.2.4, the move from v0 is a documented dump and restore, it lets pgBackRest (the chosen tool, [ADR 0004](0004-backup.md)) reach the database, and needs no password.
- **Fallback (owner's condition): B**, PostgreSQL 17 from Immich's image, if the native route lacks a tool or breaks on an update; its backups would then rest on tools that connect from outside (Barman streaming, `pg_receivewal`).
- **Not the native Immich module** (A): marked insecure in this release.
- **The move from v0's database (14) to 17** is rehearsed **on the server itself, not in the lab**: the owner will not hand over a real dump. The v0 container stays untouched as the way back; a dump of it is restored into a **second** PostgreSQL 17 instance on the same machine, the counts and a search are checked, and only then does Immich point at the new one. The size, time and index rebuild of a real library are **unmeasured**; that risk is accepted and is why the old database is kept running until the new one has been verified.

## Consequences

- If C: the database belongs to the host flake, and its backups to the pgBackRest module; the restore drill of phase 7 includes the dump and restore for any **major** change.
- Whatever is chosen: a database restore is paired with a **restore of the files to the same moment** (ADR 0005's snapshots), and this has to be part of the restore drill: a restore that brings back rows without the files is a silent failure.
