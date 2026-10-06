# Capacity: what goes on each disk, and how full it may get

The roles of the disks are in [ADR 0005](decisions/0005-storage-layout-and-filesystem.md). This page puts numbers on them. **Measured** figures were read on the real v0 machine (read-only, 2026-10-06); **estimates** say so. Re-measure in the first weeks (the commands are at the end of this page) and correct this page.

## What v0 holds today

| Place | Size | Used |
|---|---|---|
| The 2 TB disk (`/mnt/nas2`) | 1.8 TB | **513 GB** |
| The 16 TB disk's data partition (`/mnt/nas`) | 12 TB | **3.4 TB**: the media library about 1.7 TB, backups about 1.6 TB, the rest small |

The 513 GB on the 2 TB disk are, by what they are:

| What | Measured |
|---|---|
| Immich | 34 GB |
| WebDAV (phone backups) | 48 GB |
| Syncthing | 25 GB |
| Nextcloud | 15 GB |
| Jellyfin's configuration | 1.4 GB |
| iCloud photos (the service is dropped) | 56 GB |
| Vaultwarden, nginx, the dumps, the rest of the services | under 1 GB together |
| **Other content of the NAS** (not a service) | about 335 GB |

## The new layout

| Disk | What goes on it | Now | After a year (estimate) |
|---|---|---|---|
| **The 1 TB NVMe** (ZFS) | the services' live data: Immich, Nextcloud, WebDAV, Syncthing, Jellyfin's configuration, Vaultwarden, PostgreSQL | **about 125 GB** measured, and a few GB of databases | about 175 GB (the services grow about 4 GB a month, [ADR 0005](decisions/0005-storage-layout-and-filesystem.md)) |
| **The 1 TB NVMe**, the `fast` Incus pool | VMs that matter | a quota to set ([pending](pending.md)): 200 GB leaves about 600 GB | |
| **The 2 TB disk** (SMR, ext4 on LUKS), the offsite repository | a Borg repository of Immich, Nextcloud and WebDAV (97 GB of source); the photos do not compress, so the repository is about the size of the source | about 110 GB (estimate) | about 160 GB |
| **The 2 TB disk**, Incus | its state (`incus-state`) and the `smr` directory pool for throwaway VMs | about 15 GB (v0 keeps 15 GB of Incus today), and a pool budget of **200 GB** | |
| **The 2 TB disk**, the NAS share | whatever of the NAS content comes back, if all of it: about 335 GB | 335 GB | 400 GB |
| **The 16 TB disk** | the media library, the Borg repository of everything (it holds the NAS share and the services' files too), the pgBackRest repository, the Time Machine partition | 3.4 TB of 12 TB | well under the limit: the media library is what grows |

**The 2 TB disk, in total:** about 110 + 15 + 200 + 335 = **660 GB now**, about **775 GB after a year**, of about 1.7 TB usable: **under half full**.

## How full each may get

- **The 1 TB NVMe and the 16 TB disk:** under about 80% (ZFS slows down and fragments above it; the `DiskAlmostFull` alert fires below 10% free, [ADR 0012](decisions/0012-observability.md)).
- **The 2 TB disk is shingled (SMR):** it slows down a lot when it is nearly full and when it is rewritten in small pieces. Keep it **under 75%** (about 1.3 TB), which leaves about **500 GB** over the budget above. The offsite repository and the NAS share are written in large sequential runs; the pool for VMs is what suffers, which is why it holds only throwaway VMs.
- **The 513 GB of v0 are not a size to carry over:** the iCloud photos (56 GB) are not carried, and the services' data (about 125 GB) goes to the SSD, not to the 2 TB disk.

## What to check in the first weeks

Real sizes replace the estimates: `borg info` of the offsite repository, `zfs list`, `df -h` of the three disks, `du -sh` of the NAS share. If the offsite repository grows faster than the source (churn from edited files, not new ones), look at the retention ([ADR 0004](decisions/0004-backup.md)) before looking at a bigger disk.
