# 0015. Backup verification: checks that say a backup can be restored, without touching production

- **Status:** accepted (2026-10-02): the owner accepted the exceptions-register entry and asked for the full data check **every week** (Sunday) instead of every three months
- **Date:** 2026-10-02
- **Phase:** 7, Automation (follow-up)

## Context

A backup that has never been restored is a hope. The restore drill of [ADR 0014](0014-automation-and-restore-drill.md) proves that the **procedure** works, on a lab machine with generated data. It does not prove that the **real** backups restore, and it cannot be run on the real machine without destroying it. What is needed is a recurring check on the real repositories that **changes nothing in production** and **makes noise when it fails**.

## Requirements

- **Must:** non-destructive (no write to a repository, a live database or a live service); a failure reaches the owner by the channel of [ADR 0012](0012-observability.md); **a check that stops running is noticed too**; the backups themselves keep working while a check runs.
- **Should:** declared in code with as little of our own script as possible (P1); cheap on 165 GB; it must tell a *damaged* backup from a *good-looking but wrong* one.
- **Won't:** a destructive drill on the real machine.

## Candidates and results

`exp/backup-verify` (tag `exp-backup-verify`), on the integrated lab host with the drill's data (a 190 MB pgBackRest repository, two small Borg repositories). **Every figure is a lab figure**; the real repositories are 165 GB and the timings will be long.

### Borg

| Candidate | What it is | Result |
|---|---|---|
| **A. borgmatic, checks only**, next to the Borg module's jobs | `services.borgmatic` with `skip_actions = [ repo-create create prune compact ]`: it never writes a backup; the checks are `repository`, `archives`, `extract` (a dry-run extraction of the latest archive) and `data` | **works, declared, no script of ours**; both repositories checked in about **2.4 s each** (lab); the frequencies are kept by borgmatic (`1 week`, `3 months`) |
| B. borgmatic for everything (it also creates the archives) | would allow the `spot` check, a random sample of the **live** files compared with the archive | `spot` **works** (it passed on an untouched source, **failed when 40 of 200 files had changed** and when 100 had been deleted), **but** it needs two manual pieces: `borgmatic repo-create` (it does not create the repository) and a file called `xxh64sum`, which the nixpkgs `xxhash` package does not provide (a symlink to `xxhsum`) |
| C. our own unit or a hook around `borg check` | | not tried: it would be a script of ours, and A already does it |

What A does and does not see, measured on a **copy of a repository with 64 bytes of one data segment overwritten**:

| Check | Result on the damaged copy |
|---|---|
| `repository` | **fails**: "Segment entry checksum mismatch" |
| `extract` | **fails** |
| `data` (every chunk verified) | **fails**, and names the chunk |
| **`archives`** | **passes**: it reads the archives' metadata, not all the data |

So `archives` alone would miss this damage; `repository` and `extract` catch it, `data` is the thorough one.

**`spot` on archives made by the Borg module does not work**: it fails with "Cannot read configuration paths from archive due to missing archive or bootstrap manifest", a manifest only borgmatic's own `create` writes. So **A cannot tell a good-looking but wrong backup** (the wrong paths, an empty directory) from a good one; the restore drill and the sizes in the alerts are what catch that.

**A collision with the backups, found while testing:** `borg check` holds the repository exclusively. **A Borg job started meanwhile failed** (default lock wait: 1 second), which would raise `UnitFailed`. With `extraArgs = [ "--lock-wait" "7200" ]` on the jobs, a job started during a 25-second lock **waited and succeeded**. The jobs are not `oneshot` units: `systemctl start` returns at once (this bit the drill's own script).

### PostgreSQL

| Candidate | What it is | Result |
|---|---|---|
| D. the pgBackRest module | its jobs run `pgbackrest backup --type=...` only | no way to run `verify` or a restore test from the module |
| **E. a declared unit with a timer** (`pgbackrest-restore-test`) | `pgbackrest verify`; restore the latest backup into a scratch folder with **archiving off**; start a throwaway server on a Unix socket in that folder; wait for recovery to finish; `amcheck` in each database; count the assets; stop and delete | **works**: `verify` **1.4 s**, restore **26 s** (190 MB, replaying the archived WAL to its end), the three databases pass `amcheck` (72, 30 and 140 tables), **18 assets** counted, the scratch folder gone, **36 s in all**. The unit runs as `postgres` with `ProtectSystem=strict` and **no network** (`IPAddressDeny=any`) |
| F. the same inside a NixOS container with its own PostgreSQL | | not tried: the restore still needs the same few lines, and it adds a container and a second service definition |

What E showed while it was being made (each one a defect of my first version):
- `max_connections` of the scratch server **must not be lower than the primary's** (a restored standby refuses to start otherwise);
- the scratch server must be **off archiving twice** (`--archive-mode=off` on the restore **and** `archive_mode=off`, `archive_command=/bin/true` on the command line): a restored copy that pushed a WAL segment would corrupt the real archive;
- `amcheck` is **not installed** in the databases: it is created in the scratch copy only, which needs the server **promoted**, so the unit waits for the end of recovery (`pg_is_in_recovery()`);
- an immediate stop of a server that is still fetching WAL makes `pgbackrest archive-get` dump core: the cleanup uses a fast stop.

Failure detection, on a copy of the repository with one backup file overwritten:

| Step | Damaged file in an **old** backup | Damaged file in the **backup a restore uses** |
|---|---|---|
| `pgbackrest verify` | reports `status: error ... checksum invalid: 1` **and exits 0** | the same, **exit 0** |
| `pgbackrest restore` | succeeds (it does not touch that file) | **fails**, exit 29, "zst error: Data corruption detected" |

**`verify` does not fail by itself.** The unit reads its report and fails on `status: error`; and the restore of the latest backup is the check that matters for the next disaster.

## Criteria, in this order

1. **Catches damage** (measured on damaged copies).
2. **Non-destructive and safe** (archiving off, no network, read-only on the repositories).
3. **P1:** declared, little of our own.
4. **Does not disturb the backups.**
5. **Cost** (time, on real data to be measured).

## Proposed decision

**A for Borg, E for PostgreSQL, with the lock wait on the Borg jobs, and staleness alerts.**

- **Borg:** borgmatic with `skip_actions` and two configurations (one per repository, each with its own source paths): `repository`, `extract` and `data` **weekly, on Sunday** (the owner chose the weekly data check on 2026-10-02; `data` implies `archives`); the timer at 04:30; **`--lock-wait 7200` on both Borg jobs**.
- **PostgreSQL:** the unit and its timer **monthly**.
- **Alerts** ([ADR 0012](0012-observability.md)): `UnitFailed` already covers a failing check; two new rules, **`BorgChecksStale`** (the borgmatic timer silent for three days) and **`RestoreTestStale`** (the restore-test timer silent for 45 days).
- **The exceptions register gets an entry** (2) for the restore-test unit: it is a script of ours (about 20 lines) with no native way to do what it does.
- **Not adopted:** B (two manual pieces for a check that needs live-file tolerances anyway).

## The patience of the Borg jobs, and the weekly check (2026-10-02, follow-up)

The owner asked for the full data check every week; the jobs wait at most `--lock-wait` for the repository, and 2 hours was a guess. Tried in the lab on a **4 GB repository of incompressible data** (lab figures: a virtual disk, 4 vCPUs; **the real disk and CPU are unmeasured**):

| Strategy | What it does | Result |
|---|---|---|
| **A. a long `--lock-wait`** | the job waits for the check, then runs | **works**. A job started 3 s into a 23 s check finished at **60 s**: **a waiting job looks at the lock once a minute** (finishes at 60, 120, 180 s whatever the hold: 3, 10, 20, 40, 70 and 130 s were tried), so it notices the release up to a minute late. A job with no contention takes 0.6 s. With `--lock-wait 1` the job **fails at once** (exit 2) |
| **D. partial repository checks** (`borg check --repository-only --max-duration N`, in borgmatic `max_duration`) | the lock is held for at most N seconds per run and the next run **resumes** where the last stopped | **works**: slices of 3 s covered the 4 GB repository in two runs (segments 0-8, then 9-21), then started over; it **found the damaged segment in its first slice**. **But** it checks only the segment files' checksums and structure: **borg refuses `--max-duration` together with `--verify-data`**, so it never reads or decrypts the chunks. It is a weaker check than the one the owner asked for |
| **F. the backup preempts the check** (a systemd `Conflicts=` from the Borg job to the check) | starting the job stops the running check | **works** (the job ran in 0.6 s, no stale lock left, the next job fine) **but the check restarts from zero** (a full pass again: 20.5 s for 4 GB), so a check longer than the gap between two jobs would **never finish** |
| (not possible) check a snapshot or a copy | | the 16 TB disk is ext4: no snapshot; a copy of 165 GB is not a check, it is a second backup; and **opening a copy of a repository makes the real jobs fail** (found earlier) |

**How long will the check take?** The lab verified the 4 GB in **23 s, 177 MB/s** (segment checksums alone: 890 MB/s). At the same speed **165 GB would take about 16 minutes**; a spinning disk and a slower CPU could make that several times longer. It is an extrapolation, to be replaced by the first real run.

**Decision (the best of the three for the owner's requirement): A, with `--lock-wait 14400` (4 hours) on both jobs.** It keeps the check exactly as the owner asked (every byte, every week), needs no code, and 4 hours is about four times the extrapolated duration. The wait is also **the alarm time**: a backup blocked for more than 4 hours fails and raises `UnitFailed`; a longer wait would hide a hung check, because the timer-based staleness rule sees the timer firing hourly even while the job waits. D stays available as a **lighter daily addition** if the weekly check ever proves too long; F is rejected.

**One schedule only.** borgmatic had two schedules working against each other: a **daily timer** and, inside the configuration, `frequency` and `only_run_on`. Measured on paper and in the unit: a check that ends at 04:50 is *less than a week* before the next 04:30, so the weekly check would drift by a day each week; and a Sunday missed by a powered-off machine (the timer is `Persistent`) would be skipped silently, with `BorgChecksStale` quiet because the timer still fires every day. Now **the timer is weekly (Sunday 04:30, `Persistent`) and every run does all the checks**; `BorgChecksStale` waits 8 days. (The borgmatic package also delays its start by one minute: a service run takes about a minute even on a tiny repository.)

## How a failure reaches the owner (tested in the lab, 2026-10-02)

A **real** backup failure was made on the integrated lab host (the offsite repository's directory made immutable, so the Borg job could not take its lock). Times from the failure: the job fails at 0 s, `UnitFailed` is **pending after about 1 minute and firing at 6 minutes** (the rule waits 5 minutes), and **the mail arrives 13 seconds later** (Alertmanager's `group_wait` is 30 s in production; the lab's mail sink received it at 6 min 13 s). Once the repository was repaired and the job ran, the alert **cleared by itself**. The same path covers every failing unit: the Borg jobs, pgBackRest's, borgmatic's checks, the restore test, the certificate orders.

The staleness rules read `node_systemd_timer_last_trigger_seconds` with the timers' real names (checked against the live metrics: `borgbackup-job-*.timer`, `pgbackrest-default-*.timer`, `borgmatic.timer`, `pgbackrest-restore-test.timer`), and all rules load without error. **Not tested:** a staleness rule actually firing (it needs the timer to stay silent for hours or days), a real mail through Brevo, the heartbeat at Healthchecks.io.

## What this does not cover

- **A good-looking but wrong backup** (the Borg module's archives cannot be spot-checked): caught by the periodic restore drill and by the backup sizes, not by a check.
- **The duration on the real data**: `borg check --verify-data` reads every chunk of a repository of that size from a spinning disk, probably **hours**; it holds the repository exclusively, and the jobs wait for it (`--lock-wait`). The quarterly schedule is a guess to be corrected by the first real run.
- **The offsite copy**: the verification of the repository at the provider is not designed here ([ADR 0007](0007-offsite-copy.md)).
- **Application-level consistency** (Nextcloud's database against its files): only the restore drill looks at it.
- **A check that runs but a mail that cannot be sent** is silent: if Brevo is unreachable or the credentials are wrong, failures are raised and not delivered; only the heartbeat's own silence (a dead machine or a dead Alertmanager) is noticed from outside. A periodic test mail is not designed.
- The restore-test unit checks the **latest** backup with its WAL; older backups are checked by `verify` only.

## Found along the way

- **The integrated backup config named the wrong folder for Vaultwarden** (`/var/lib/bitwarden_rs`; the module's data is in `/var/lib/vaultwarden`): its **RSA key and its attachments were not in the backup**, and the Borg jobs logged a warning on every run that `failOnWarnings = false` hid. The restore drill passed because Vaultwarden's database is in PostgreSQL. **Fixed**, and the drill now compares the key's checksum before and after.
- The drill's seed step raced the Borg jobs (not `oneshot`): fixed by waiting for them.
- **Never open a copy of a repository under the account that runs the backups**: Borg remembers where each repository id was last seen, and after a check on a *copy* of the repository the real jobs failed with "previously located at /tmp/...: Do you want to continue? Aborting" until `BORG_RELOCATED_REPO_ACCESS_IS_OK=yes borg list` was run once. A lab mistake of mine, but the same would happen after any restore of a repository copy to a new path.

## Answered by the owner (2026-10-02)

1. The 20-line restore-test unit in the exceptions register: **accepted** (entry 2).
2. The full data check: **every week**, not every three months. The cost on the real data is a guess to be measured: the `--lock-wait` of the Borg jobs (2 hours) may have to grow if the check on 165 GB takes longer than that, or the hourly jobs will fail after waiting.

## Questions that were open

1. **Accept an entry in the exceptions register** for a 20-line unit of ours, in exchange for a real restore test of the databases every month?
2. **The `data` check every three months**: acceptable even if it holds the Borg repositories for hours (the jobs wait)?

## Consequences

- `modules/verify.nix` holds both; `backup.nix` gets the lock wait; `observability.nix` two rules.
- The first deployment starts these timers: their first runs on the real data **measure** what this ADR could only estimate.
