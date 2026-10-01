# S1 results (2026-10-01)

The read-only inventory of [S1](S1-storage-inventory.md), run over SSH by the assistant on the owner's instruction. **No `sudo` was available** (it asks for a password and none was given), so everything that needs root was skipped: SMART read directly, and any folder not readable by the owner's own user. The v0 `smartcheck` container's log was used for health instead.
Disk models and serial numbers are deliberately not written here (they stay out of the repository).

## The machine

| | |
|---|---|
| TPM | **present** (`/dev/tpm0`, `/dev/tpmrm0`): the LUKS-with-TPM route of [ADR 0005](../decisions/0005-storage-layout-and-filesystem.md) is possible |
| Boot | UEFI |
| Memory | 4.9 GiB in use by the v0 services, the rest page cache |

## The disks

| Role today | Size | Used | Kind | Health (v0 `smartcheck`, 12-hourly) |
|---|---|---|---|---|
| System | 119 GB SATA SSD | 76 GB of 98 GB (82%) | SSD | not covered by `smartcheck`: unknown |
| Large disk: media, the local Borg repositories, a Time Machine partition | 14.6 TiB | 3.1 TB of 12 TB (data partition), 0.7 TB of 2.8 TB (Time Machine partition) | HDD, 9,558 power-on hours | passed; no reallocated, pending or uncorrectable sectors |
| Small 2.5-inch disk: Docker data, Incus, bulk archives | 1.8 TiB | 513 GB (30%) | **SMR**, confirmed against the manufacturer's documentation for its model family; 31,657 power-on hours (3.6 years) | passed; no reallocated or pending sectors, but **1,475 command timeouts** recorded over its life |
| A USB stick (Ventoy, the installer ISOs) | 231 GB | | not part of the system | |

Also present: an **Incus thin pool of 200 GB** (VM disks), whose backing device is not visible without root.

## What the services hold today

| Data | Size | Growth |
|---|---|---|
| Docker data of the services, in total | 165 GB | |
| Immich library | 34 GB | **9.5 GB in the last 90 days** (about 3 to 4 GB a month) |
| iCloud photos (icloudpd) | 56 GB | none in 90 days |
| WebDAV (phone backups) | 48 GB | |
| Syncthing | 25 GB | |
| Everything else (Nextcloud 1.1 GB, Jellyfin 1.9 GB, Plex 0.3 GB, Vaultwarden, nginx, certbot, dumps) | about 4 GB | |
| Immich database dump | **59 MB** compressed | |
| Media library | 1.4 TB (large disk) + 91 GB (music, small disk) | |
| Local Borg repositories | 1.1 TB (large disk) | |
| Bulk archives (game backups and similar) | about 275 GB (small disk) | |
| Time Machine | 0.7 TB | replaceable |

## What this says for the layout

- **The data that needs to be fast and redundant is small**: the services' data is about **165 GB**, and the databases a few GB at most. Everything else is bulk (media, archives, backups) and belongs on the large HDDs.
- The system can be **rebuilt from the flake**, so it does not need the redundancy the data does.
- The owner's 1 TB-per-SSD idea is more than the data needs; see the sizing options in [ADR 0005](../decisions/0005-storage-layout-and-filesystem.md).
