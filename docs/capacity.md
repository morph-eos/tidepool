# Capacity: what goes on each disk, and how full it may get

The roles of the disks are in [ADR 0005](decisions/0005-storage-layout-and-filesystem.md). This page puts numbers on them for the reference setup: a 1 TB SSD, a mid-size disk of about 2 TB (SMR) and a large disk of about 16 TB. The figures are rounded, and the ones that are not measured are estimates. On a real deployment, measure again in the first weeks (the checks are at the end of this page) and correct this page.

## What dominates

The data that needs to be fast and redundant is small. In the reference setup it is on the order of 100 to 150 GB, mostly a photo library and phone backups, with the databases a few GB at most; it grows about 4 GB a month. Everything else is bulk (media, archives, backups) and belongs on the large disks. The system is rebuilt from the flake, so it needs none of the redundancy the data does.

## The layout

| Disk | What goes on it | Now | After a year (estimate) |
|---|---|---|---|
| SSD, 1 TB (ZFS) | the services' live data: Immich, Nextcloud, WebDAV, Syncthing, Jellyfin's configuration, Floppy's files (the database is PostgreSQL's), Vaultwarden, PostgreSQL | about 125 GB, and a few GB of databases | about 175 GB |
| SSD, the `fast` Incus pool | VMs that matter | a quota to set ([pending](pending.md)): 200 GB leaves about 600 GB | |
| Mid-size disk (SMR, ext4 on LUKS), the offsite repository | a Borg repository of the data that cannot be recreated (about 100 GB of source); photos do not compress, so the repository is about the size of the source | about 110 GB | about 160 GB |
| Mid-size disk, Incus | its state (`incus-state`) and the `smr` directory pool for throwaway VMs | about 15 GB, and a pool budget of 200 GB | |
| Mid-size disk, the NAS share | files that are not a service's data, a few hundred GB | 335 GB | 400 GB |
| Large disk | the media library, the Borg repository of everything (it holds the NAS share and the services' files too), the pgBackRest repository, the Time Machine partition | about a quarter of the data partition | well under the limit: the media library is what grows |

The mid-size disk in total: about 110 + 15 + 200 + 335 = 660 GB now, about 775 GB after a year, of about 1.7 TB usable. That is under half full.

## How full each may get

- The SSD and the large disk: under about 80% (ZFS slows down and fragments above it; the `DiskAlmostFull` alert fires below 10% free, [ADR 0012](decisions/0012-observability.md)).
- The mid-size disk is shingled (SMR): it slows down a lot when it is nearly full and when it is rewritten in small pieces. Keep it under 75% (about 1.3 TB), which leaves about 500 GB over the budget above. The offsite repository and the NAS share are written in large sequential runs; the pool for VMs is what suffers, which is why it holds only throwaway VMs.
- What a migration carries over is not what the old disks held: data of a service that is dropped is not carried, and the services' data goes to the SSD, not to the mid-size disk.

## What to check in the first weeks

Real sizes replace the estimates: `borg info` of the offsite repository, `zfs list`, `df -h` of the three disks, `du -sh` of the NAS share. If the offsite repository grows faster than the source (churn from edited files, not new ones), look at the retention ([ADR 0004](decisions/0004-backup.md)) before looking at a bigger disk.
