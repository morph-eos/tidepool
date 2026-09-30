# Pending items

Things deliberately postponed, so they are not lost. Each has an owner decision or a gate behind it. Updated 2026-09-30.

## Waiting for the owner's answer

| Item | Why it waits | Blocks |
|---|---|---|
| Where the `age` key is kept (Proton Pass, a paper copy) and where non-secret variables live (a separate private repository, or encrypted in this one) | "we talk about it later" | [ADR 0003](decisions/0003-secrets.md) |
| New services to add next to the v0 ones (for example a replacement for Trakt) | application layer, not infrastructure | phase 4 |

## Gates and checks that need the real server or a maintenance window

| Item | What it needs |
|---|---|
| G2, hardware transcoding with ffmpeg in a container | the server installed, a short maintenance window |
| G3b, the Proton Drive CLI keeping its login in the keyring of a real desktop session | a desktop session on the real machine |
| S1, read-only inventory of the disks (models, SMART, usage, RAM) | a run on the server, about 10 minutes |
| Confirming the small disk is SMR against its datasheet | the datasheet of the model (taken as SMR for now) |

## Lab work still to do

| Item | Notes |
|---|---|
| PostgreSQL 14 with Immich's vector extension in a restore | check Immich's documentation for the extension and its version first |
| The offsite layer: restic, Borg or Kopia to an S3 bucket or an SSH server, against the official Proton Drive CLI | the v0 mirror to Proton Drive is a custom Borg-aware script; under P1 it needs a native replacement or an entry in [the register](exceptions.md) |
| Containers against native NixOS modules for each service (Immich, Jellyfin, Nextcloud, Vaultwarden, and the rest): lines of configuration, update, restore | phase 4 |
| Disk layout and filesystem on the real disks (a small SSD for databases, a possible second fast 2 TB, the SMR disk as a sequential target) | after S1 |
| The root `README.md` still describes v0 | rewrite when the first phase closes |

## Housekeeping

- The old repository `nas-scripts-history` was deleted by the owner (2026-09-30).
