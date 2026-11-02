# S1 results: the storage inventory of the reference case

The read-only inventory of [S1](S1-storage-inventory.md), run over SSH. No `sudo` was available, so everything that needs root was skipped: SMART was read from the health container's log instead, and any folder not readable by the user was not measured. Disk models and serial numbers are deliberately not written here. Sizes are rounded.

## The machine

| | |
|---|---|
| TPM | present (`/dev/tpm0`, `/dev/tpmrm0`): the LUKS-with-TPM route of [ADR 0005](../decisions/0005-storage-layout-and-filesystem.md) is possible |
| Boot | UEFI |
| Memory | under 5 GiB in use by the services, the rest page cache |

## The disks

| Role | Size | Kind | Health |
|---|---|---|---|
| System | about 120 GB, mostly used | SATA SSD | not covered by the container's check: unknown |
| Large disk: media, local Borg repositories, a Time Machine partition | about 16 TB | HDD, under 10,000 power-on hours | passed; no reallocated, pending or uncorrectable sectors |
| Mid-size disk: Docker data, Incus, bulk archives | about 2 TB | SMR (confirmed against the manufacturer's documentation for its model family), about 3.5 years powered on | passed, but a long record of command timeouts over its life |

An Incus thin pool of about 200 GB (VM disks) was also present, with a backing device that is not visible without root.

## What the services hold

| Data | Size | Growth |
|---|---|---|
| The services' data, in total | about 165 GB | a few GB a month |
| The photo library | tens of GB | about 3 to 4 GB a month |
| Phone backups, synced folders, an old photo import | tens of GB each | little |
| Everything else (Nextcloud, Jellyfin, Vaultwarden, nginx, certificates, dumps) | a few GB | |
| The Immich database dump | tens of MB compressed | |
| Media library | about 1.5 TB | |
| Local Borg repositories | about 1 TB | |
| Bulk archives | a few hundred GB | |

## What this says for the layout

- The data that needs to be fast and redundant is small: about 165 GB, and the databases a few GB at most. Everything else is bulk (media, archives, backups) and belongs on the large HDDs.
- The system can be rebuilt from the flake, so it does not need the redundancy the data does.
- A 1 TB SSD per member of a mirror is more than the data needs; the sizing options are in [ADR 0005](../decisions/0005-storage-layout-and-filesystem.md).
