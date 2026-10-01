# 0007. The offsite copy

- **Status:** accepted in part (2026-10-01): Borg is the tool and Hetzner Storage Box the clean reference and fallback; **Proton Drive through a small container of our own is tested first**, against criteria fixed now; the destination is settled by that test
- **Date:** 2026-09-30
- **Phase:** 2, Backup (layer 3 of [ADR 0004](0004-backup.md))

## Context

In v0 the offsite copy is a Borg repository (encrypted, pruned to 7 daily, 4 weekly, 6 monthly) of **about 200 GB**: the family's data, the compose files and scripts, the music, and the database dumps. It is mirrored to Proton Drive by a **custom script** that knows Borg's repository layout and repairs the remote copy; it runs as the desktop user because the official CLI keeps its login in that user's keyring. Under [P1](../principles.md) that script is glue, and gate G3b (does the CLI's keyring work in a real desktop session on NixOS) is still open.

The owner's constraints: **a few euros a month**, no second site (a relative's house) and no other subscription active today, the media library **stays at home**, and the data may grow "a bit". The 16 TB disk at home already receives a copy of everything ([ADR 0005](0005-storage-layout-and-filesystem.md)); this layer is the one that survives a fire or a theft.

## Requirements

- **Must:** encrypted on the client (the provider never sees the key or the plaintext); history kept (an overwritten or deleted file can be recovered from an earlier state); a restore of any state verified byte for byte; a wrong passphrase refused; a damaged repository noticed.
- **Should:** runs from a NixOS module with a timer (no glue); resists an attacker who has the machine's credentials (**append-only**, or object lock); incremental (only what changed is sent); a destination costing a few euros a month for 200 GB to 1 TB.
- **Won't:** the media library; a second site.

## What the destinations are (prices as reported by the sources on 2026-09-30; check the provider's page when ordering)

| Destination | Protocols | Price for 200 GB / 500 GB / 1 TB a month | Notes |
|---|---|---|---|
| [Hetzner Storage Box BX11](https://www.whtop.com/plans/hetzner.com/128269) | SFTP, rsync, **BorgBackup**, WebDAV | a flat **€3.20 for 1 TB** (VAT excluded), unlimited traffic | fixed size steps; Borg is a first-class protocol |
| [Backblaze B2](https://www.backblaze.com/cloud-storage/pricing) | S3-compatible | **$6.95 per TB**: about $1.40 / $3.50 / $6.95; egress free up to 3× the stored amount | pay for what is stored; **object lock** available |
| [BorgBase](https://www.borgbase.com/) | Borg and restic repositories over SSH | about **$30 a year for 250 GB**, $110 a year for 1 TB ([pricing](https://www.spotsaas.com/product/borgbase/pricing)) | append-only is a setting of the repository |
| [Wasabi](https://tech-insider.org/backblaze-b2-vs-wasabi-vs-s3-2026/) | S3-compatible | $6.99 a month, **1 TB minimum** | no egress fee, but the minimum alone exceeds the budget for 200 GB |
| **Proton Drive** (the owner's existing plan) | the **official CLI** only | included in the plan the owner already has (space not checked) | see below |

**Proton Drive cannot be used through a general tool.** rclone's Proton backend is in beta and in practice unusable: [CAPTCHA errors on every login](https://github.com/rclone/rclone/issues/9397), [uploads broken since about November 2025](https://gist.github.com/tomholford/a5a043648a16974753e973b167785670) (Proton now requires a per-block verification token), and [no active maintainer](https://forum.rclone.org/t/proton-drive-mark-it-as-unsupported/52742). The official CLI is what v0 uses, through the custom mirror script. So Proton Drive either stays as a **custom-script exception** (recorded in [the register](../exceptions.md), with the keyring gate G3b) or is dropped.

## Options considered (tool and backend)

| | Client-side encryption | NixOS module | Append-only against a stolen credential |
|---|---|---|---|
| restic, S3 | yes | `services.restic.backups` (timers, prune options, an `environmentFile` for the S3 keys) | **no**, unless the bucket has object lock |
| restic, REST server | yes | the client as above; the server as `services.restic.server` with `appendOnly` | **yes** |
| Borg over SSH | yes | `services.borgbackup.jobs` (client) and `services.borgbackup.repos` (server side, with `authorizedKeysAppendOnly`); `services.borgmatic` also exists | **yes** (an append-only key) |
| Kopia, S3 | yes | **none** | **no** |

## Results

`lab/offsite-bakeoff.sh` in the NixOS lab VM: a 320 MB stand-in data set (120 incompressible 2 MB "photos", 1,500 small "documents", 20 4 MB "music" files); the S3 endpoint is Garage on localhost, Borg's server is the NixOS module over SSH.
The second backup follows a change of 30 MB (5 files rewritten, 10 added, 5 deleted). Times are a toy on localhost and say nothing about the uplink.

| | restic, S3 | restic, REST (append-only) | Borg, SSH (full access) | Borg, SSH (append-only key) | Kopia, S3 |
|---|---|---|---|---|---|
| First backup, repository size | 3.4 s, 320.5 MB | 2.0 s, 320.4 MB | 4.2 s, 320.6 MB | 4.2 s, 320.6 MB | 3.2 s, 321.0 MB |
| Second backup, growth | 1.4 s, +30.1 MB | 1.1 s, +30.1 MB | 1.8 s, +30.0 MB | 1.8 s, +30.0 MB | 0.9 s, +30.0 MB |
| Restore of the latest state, byte for byte | identical, 2.1 s | identical, 1.3 s | identical, 4.2 s | identical, 4.1 s | identical, 10.2 s |
| Restore of the **first** state | identical | identical | identical | identical | identical |
| Wrong passphrase | refused | refused | refused | refused | refused |
| **An attacker with the client's credentials deletes the history** | **all snapshots gone** (an S3 key that can write can delete) | **refused: 2 snapshots left** | **repository deleted** (full-access key) | **2 archives still listed and the latest restores** | **all snapshots gone**; no append-only mode |
| Damage to one repository file, then the tool's own check | not run on this backend | **detected** by `restic check --read-data` (a failing blob is named) | **detected** by `borg check --verify-data` (segment checksum mismatch) | as the full-access one | detected by `kopia content verify --full` and, on a fresh connection, by `snapshot verify`; the scripted run after an earlier verification **did not** (it can read from its local cache) |

The amounts sent are the same for every tool (the changed data, deduplicated); on this data no tool is ahead. The differences are elsewhere:

- **Only two setups survive a stolen credential**: an append-only **Borg** key, and an append-only **restic REST server**. With plain S3 the same key that writes can delete. A provider feature closes it (B2's object lock, or a key without delete permission); it was not tried here, because the lab's Garage has neither.
- **Append-only has a price**: pruning old history also needs a delete, so it has to be done with a *second, privileged* credential from somewhere else (or by the provider's lifecycle rules), not from the machine that is backed up. Until then the repository only grows.
- **Kopia** is as fast and as small as the others but has **no NixOS module** and no append-only mode: under P1 that is a cost with no offsetting gain here.
- **restic** talks to every backend with one client; **Borg** needs a Borg-speaking server (Hetzner Storage Box, BorgBase, or your own) but makes append-only a first-class key setting.

## What was not tested

- **A real provider**: latency, throughput, the first upload of 200 GB over the home uplink (at 50 Mbit/s up, 200 GB is about 9 hours of saturated link; check the real speed), a provider's own append-only or object-lock configuration.
- **restic or Borg against Hetzner Storage Box or BorgBase** (the protocol is the same as the lab's SSH server, but a provider restricts what a key may do in its own way).
- **The official Proton Drive CLI** (it needs the owner's login and a desktop session) and gate G3b.
- **pgBackRest writing straight to an S3 repository** for the databases: it did (ADR 0004, round 2), so the database repository can reach the offsite by its own native repository line instead of through the file tool.
- Real restore time at 200 GB, and memory use of the tools at that size.

## Criteria

1. **Survives a stolen credential** (append-only or object lock), then **integrity** and **correct restores** (measured).
2. **P1:** a maintained NixOS module with a timer, secrets by file (through the mechanism of [ADR 0003](0003-secrets.md)), no glue (Proton's mirror script is the glue to beat).
3. **Cost** for 200 GB to 1 TB, with no other subscription needed.
4. **Moving parts** and what an update costs.

## Decision (2026-10-01, revised the same day)

The owner's order of preference: **Proton Drive first, if it can be made clean enough; Hetzner as the alternative**. Proton Drive is already part of the plan the owner pays for, so it costs nothing more. Hetzner is the cleanest solution and stays the **reference and the fallback**. The tool for the files is **Borg** in both cases.

- **Reference and fallback: Borg over SSH to a Hetzner Storage Box** (the 1 TB plan, about €3.20 a month before VAT, as reported on 2026-09-30). A native NixOS module with a timer; the passphrase and SSH key are secrets delivered by the mechanism of [ADR 0003](0003-secrets.md); encrypted on the client. **Protection against a stolen credential or a mistake: the provider's automatic snapshots** (10 slots on this plan, read-only over SSH under `/.zfs/snapshot`, removable only through the Hetzner account, which the server never holds); no append-only key and no privileged prune job run by hand. Hetzner does not document restricting a key to `borg serve --append-only`, so that is not relied on.
- **To test first: Proton Drive, through a small container that holds the official CLI and a dedicated repository of our own** (the code and its tests live in that repository; the image is built from it and pinned by digest). The container's job is the one v0's script has: keep a copy of the local Borg repository on Proton Drive and say so loudly when it cannot.
  Under [P1](../principles.md) this is a custom component: an **exception to enter in [the register](../exceptions.md)** if it is adopted, with what it is, why there is no native way, who keeps it up to date and the test that runs at every update.
  It is tested **one or two phases from now**, once the server runs on NixOS, against criteria fixed **now, before testing**:
  1. **Headless login:** the CLI can authenticate and keep its session without a desktop session or the desktop keyring (its help shows `auth login` opening a browser, with the session in the user's keyring; whether a container can hold it in a volume, or log in with a token, is unknown).
  2. **Unattended:** it runs from a timer, survives a reboot and an expired session, and **fails loudly** (a notification) when the login lapses instead of silently stopping, which is what Databasus did when its key was lost.
  3. **Updates:** a new version of the CLI needs no change in our code, only the test below; the image is pinned by digest and rebuilt on purpose.
  4. **Size:** the repository's own code stays small and readable; a number is fixed when the first version exists (v0's script is the baseline to beat).
  5. **Restore:** a full restore of the Borg data **from Proton** is rehearsed byte for byte, as in the lab for the other candidates.
  6. **Deletion:** what Proton's trash and file versions give against a deleted or overwritten file is **measured** (Hetzner's snapshots are the bar).
  7. **First upload:** about 200 GB at the real uplink, and whether Proton's limits allow it.
  If it meets these, it is adopted (and Hetzner is not opened). **If it fails any must-have (1, 2 or 5), Hetzner is the answer.**
- **Retention: a few weeks**, not v0's six months: Borg `keep-daily 7` and `keep-weekly 4`, no monthly.
- **Custody of the repository passphrase:** as the age key: Proton Pass, with a printed copy if possible.
- **Not Kopia** (no module, no append-only). **Not restic to S3** for now: equal in the lab; Borg gives the cheapest step for 1 TB at Hetzner.
- **The databases** can also go offsite through pgBackRest's own second repository on a destination it can write to (SFTP or S3, so Hetzner, not Proton Drive); whether to do that, or rely on the Borg copy of pgBackRest's repository directory, is decided when the databases are moved (phase 4).

## Consequences

- Pruning runs on the machine itself (Borg `prune` from its module); protection comes from the provider's snapshots. **A restore from a snapshot** (the path under `/.zfs/snapshot`) must be part of the restore drill of phase 7.
- The client secrets (the repository passphrase, the SSH key or S3 keys) are secrets delivered by the mechanism of [ADR 0003](0003-secrets.md); **losing the passphrase loses the backup**, so it is kept in the same two places as the `age` key.
