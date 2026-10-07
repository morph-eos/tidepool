# Moving v0's data to tidepool

Rehearsed in the lab on **2026-10-05** against a replica of v0 (`lab/v0-replica/`: the same services in Docker, seeded through their own APIs), without touching the real machine. The driver is [lab/v0-migration-u25.sh](../lab/v0-migration-u25.sh); the result of the last run was **15 checks passed, 0 failed**. The replica runs v0's exact versions, read on the real machine on 2026-10-06 (Nextcloud 33.0.2, Immich 3.2.1, Jellyfin 12.1, Vaultwarden 1.37.1, Syncthing 2.0.14), so the rehearsal includes the version steps the real move makes: Nextcloud 33.0.2 to 33.0.9, Immich 3.2.1 to 3.2.4, Syncthing 2.0.14 to 2.1.3.

## What the rehearsal proves, and what it does not

| Proven | Not proven |
|---|---|
| Every service's data arrives and answers the way v0's did (table below) | Timings with the real data sizes (the replica holds 12 photos, 7 files) |
| The procedure is scripted, ordered, and repeatable | Whatever else differs between the replica and the real v0 (see "Differences to check on the real machine") |
| Gaps in the first draft of the procedure were found and fixed (last section) | The 513 GB of NAS data: it is a plain copy, not rehearsed at that size |

## Procedure, in order

Each step starts from a stopped service on the new host and a v0 that is left running until its dump is taken.

| Service | How | Check that passed |
|---|---|---|
| **Immich** | `pg_dump` of v0's PostgreSQL 14, Immich's documented `sed`, restored into the native 17 ([ADR 0006](decisions/0006-postgresql-version-and-immich.md)); the library copied | asset count equal; the admin can log in |
| **Nextcloud** | on v0, `occ db:convert-type` MariaDB to PostgreSQL into a temporary PostgreSQL container, `pg_dump` of it, restore into the native one; the data directory and `config.php` copied | version equal, share token equal, md5 of every user file equal, WebDAV login of a migrated user answers 200 |
| **Vaultwarden** | the new instance creates the schema, is stopped, `PRAGMA journal_mode=delete` on the SQLite file, then pgloader (data only) as the `vaultwarden` user; `rsa_key.pem` and attachments copied | users, ciphers and the signing key's hash equal |
| **WebDAV** | files copied; v0's `user.passwd` (bcrypt, `$2y$`) becomes the `webdav-htpasswd` secret as it is | right password passes nginx's basic auth, wrong one gets 401 |
| **Syncthing** | `restoreIdentity = true` (certificate and key as sops secrets), the folder declared in the host, the folder's files copied | device ID and folder list equal |
| **Jellyfin** | configuration directory copied; `jellyfin.mediaMounts` keeps the container-side paths v0 used | users equal, libraries point at the same container paths |

Measured on the replica: Immich dump 3 s, Nextcloud conversion 18 s, everything else seconds; the whole stage sequence took about 7 minutes, almost all of it waiting for image pulls.

## Gaps the rehearsal found (all fixed in the script)

1. **`config.php` was copied after maintenance mode was switched on**, so the new host started in maintenance mode and `nextcloud-setup` refused to run. Copy it first. The module's own overrides (database type, data directory, app paths) win over v0's values in the copied file, so copying it whole is safe and keeps `instanceid`, `passwordsalt` and `secret`.
2. **pgloader through a socket**: the URL form `postgresql:///db?host=/run/postgresql` does not parse in 3.6.9; use `postgresql://user@unix:/run/postgresql:/db`. Peer authentication then needs pgloader to run as the database user (not as `postgres`) with a `HOME` that user owns. The filter for SQLite is `EXCLUDING TABLE NAMES LIKE`.
3. **`sqlite3 ... "PRAGMA journal_mode=delete;"` prints `delete` to stdout**; redirected into the copied file it corrupted it ("file is not a database"). Send it to `/dev/null`.
4. **Temporary PostgreSQL for the conversion**: right after the image is pulled the first connection can fail; the script waits for `pg_isready`, and `occ db:convert-type` ends with a usage text that is noise when the data arrived (check the row counts).
5. **Checksums depend on the sort locale**: v0's recorded hash and the new host's differed only by ordering; both sides now use `LC_ALL=C`.
6. **Nextcloud's PostgreSQL sequences stayed at their start values** (`occ db:convert-type` copies the rows, not the counters): the first insert into `oc_activity` hit a duplicate key and `nextcloud-cron` failed on every run. [The SQL](../lab/v0-migration-u25-nextcloud-sequences.sql) sets every sequence to its column's maximum plus one (ids beyond the sequence's range, as in `oc_jobs`, are ignored); the verification now runs the cron job. Immich (a plain dump) and Vaultwarden (pgloader's `reset sequences`) do not have the problem.

## Differences to check on the real machine

- **Nextcloud's patch step is rehearsed**: v0 is on 33.0.2 and the module on 33.0.9; the first start ran the upgrade (`occ upgrade`) without incident and everything verified. Nothing is left to check here except the real data's size.
- **Syncthing 2.0.14 to 2.1.3 is rehearsed** (the replica runs 2.0.14): the device ID and the folder list survive. What the real index database holds, and how long it takes to settle, depends on the real data.
- **Jellyfin media**: v0 has two media trees, and the libraries point at their container paths (`/media`, `/media2`). Both go on the 16 TB disk, and `services.jellyfin.mediaMounts` maps each container path to its folder there (the private `host.nix`); the tree that was on the 2 TB disk is copied to the 16 TB disk **before the 2 TB disk is formatted** (runbook 1.1 and 1.2).
- **Time Machine**: v0's partition is HFS+, which Linux cannot write when it is journaled; it is made ext4 and the Mac starts a fresh backup (runbook 1.2).
- **`smartcheck`** is not carried over: the monitoring layer replaces it ([ADR 0012](decisions/0012-observability.md)).
