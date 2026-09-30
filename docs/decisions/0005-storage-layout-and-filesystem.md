# 0005. Storage layout and filesystem

- **Status:** proposed (experiment done; two answers from the owner needed before deciding)
- **Date:** 2026-09-30
- **Phase:** 2, Backup (it comes before the backup tool because the layout decides what the tool can rely on)

## Context

v0 keeps everything on ext4, which gives no protection against a bit that flips on a disk: a block that goes bad is read back as if it were good, and then backed up as if it were good.
The storage is about to be reorganized: a **third disk for the media library**, and the current **large disk as the backup target for everything**, library included
(the owner's answers in [ADR 0004](0004-backup.md)). The library does **not** go offsite: the disk that would hold it, and its running cost, are out of proportion to its value.
The family's data (photos, documents, databases) does go offsite, and is also covered by the local copy on the large disk.

## Requirements

- **Must:** a corrupted block is **noticed** (an error, not wrong data); a periodic check (scrub) finds latent damage before a restore needs the data;
  works on NixOS with the pinned kernel; cheap local snapshots, so a mistaken delete or an overwrite is undone in seconds.
- **Should:** incremental replication between disks that sends only what changed; a way to back up to an **untrusted** remote without giving it the key;
  a modest memory footprint (the machine is also a media center); self-repair where a second copy exists.
- **Won't:** RAID5/6-style parity on btrfs (not considered safe), and any setup that needs the owner to learn a storage stack before the data is safe.

## Options considered

| Option | Branch / tag |
|---|---|
| A. ext4, as in v0 (the baseline) | none |
| B. btrfs | `exp/storage-fs`, tag `exp-storage-fs` |
| C. ZFS (OpenZFS 2.4.4 on the NixOS 26.05 kernel 6.18.54) | `exp/storage-fs`, tag `exp-storage-fs` |

## Criteria, in this order

1. **Does it notice corruption, and can it repair it** (measured).
2. **Snapshots and replication:** cost and size of what is sent.
3. **Operational fit:** memory, kernel coupling, the tools to manage snapshots on NixOS, what a restore looks like.
4. **Offsite story:** can a snapshot go to a remote that is not trusted.
5. **Effort and moving parts.**

## Results

`lab/fs-bakeoff.sh` runs the same tests inside a NixOS lab VM (4 cores, 5.6 GB RAM, 6 GB disks, 20,000 files of 1 KiB). The corruption test writes a file whose first block holds a known marker,
finds that block on the raw device and overwrites 4 KiB of it, bypassing the filesystem, then reads the file back.

| Test | A. ext4 | B. btrfs | C. ZFS |
|---|---|---|---|
| F1 corrupted block, one disk, no redundancy | **silent**: the read succeeded with wrong content, no error anywhere | **detected**: the read fails with an I/O error; scrub reports 1 uncorrectable checksum error | **detected**: the read fails with an I/O error; scrub reports 1 data error |
| F2 the same with a second copy on the same disk (btrfs `data=dup`, ZFS `copies=2`) | not available | **repaired** from the second copy; scrub then finds no errors | **repaired** from the second copy; scrub finds no errors |
| F3 snapshot of 20,000 files | 0.25 s for a hard-link copy, which is not a snapshot (an overwritten file loses its old content) | **0.06 s** | **0.04 s** |
| F4 first replication to a second filesystem | rsync, 1.0 s | send/receive, 1.1 s | send/receive, 0.4 s |
| F4b incremental replication after 1% of the files changed | rsync, 0.13 s and 205 KB sent, but it has to walk all the files | send/receive, **225 KB sent**, only what changed | send/receive, **5.3 MB sent**, only what changed (records are 128 KiB, so a 1 KiB change ships a whole record) |
| F4c replica identical to the source | not checked | yes (sampled checksums) | yes (sampled checksums) |
| F5 memory | none | none to speak of | 90 MiB of cache after the test (capped by default at about half the RAM, given back under pressure) |

### What the test does not show

- **The scale is a toy.** Six-gigabyte disks and twenty thousand tiny files say *whether* each system notices, repairs and replicates, not *how fast* they are on an 8 TB disk of photos.
  The timings must not be used to pick a winner. The ZFS compression ratio (1.00x) is meaningless here, because the test data is random.
- **A single disk cannot repair itself**, in either system, without a second copy. For the media disk that second copy is the backup on the large disk: the filesystem *finds* the bad file, and the backup *replaces* it.
- **The "space held by a snapshot" number is not comparable** between the two (btrfs reported 0 bytes exclusive, which is not informative); a real workload would be needed.

### What the documentation adds (read, not run)

- **Encryption:** ZFS encrypts per dataset and can send a snapshot **encrypted (a raw send)** to a remote that never sees the key. btrfs has no native encryption and is normally put on top of LUKS
  ([Botmonster](https://botmonster.com/self-hosting/btrfs-vs-zfs-filesystem-data-protection/), [DataStorageReport](https://datastoragereport.com/zfs-vs-btrfs-filesystem-choice-impacts-nas-reliability/)).
- **Kernel coupling:** btrfs is in the mainline kernel. ZFS is an out-of-tree module, and on NixOS it **refuses to evaluate on a kernel it does not support**, so the kernel stays on the LTS line
  ([NixOS wiki: ZFS](https://wiki.nixos.org/wiki/ZFS)). That is compatible with pinning, and it constrains upgrades.
- **Memory:** btrfs fits a smaller budget ([Klara Systems](https://klarasystems.com/articles/zfs-vs-btrfs-architects-features-and-stability/)); the ZFS cache can be capped.
- **Tooling on NixOS:** `services.sanoid` and `syncoid` for ZFS snapshots and replication; `btrbk` for btrfs ([Btrbk on the NixOS wiki](https://wiki.nixos.org/wiki/Btrbk)). Sanoid's own README says btrfs support is shelved.
- **Parity RAID:** ZFS raidz is mature; btrfs RAID5/6 is still not recommended. It does not matter here (single disks and a mirror at most), and it matters if the layout ever changes.

## Decision

_Pending. Both B and C pass everything that matters; A fails the first criterion, and that is the reason to leave ext4 behind._

What would tip it, and only the owner can say:

1. **Is the offsite copy meant to be a replication of snapshots to a remote machine or service** (then ZFS raw send is a real advantage), **or a file-level backup tool** such as restic or Borg to object storage or Proton Drive
   (then the filesystem does not matter for the offsite, and btrfs's lighter footprint and mainline kernel are attractive)?
2. **How many disks hold the family's data, and in what arrangement?** Is it the existing 2 TB disk, the system disk, a mirror of two? A mirror gives self-repair for the data that matters most; a single disk only gives detection.

## Layout proposals (to compare once the numbers are in)

The owner has not decided the arrangement of the disks yet, so these are proposals to choose between, not a plan. The sizes come from [the inventory gate S1](../gates/S1-storage-inventory.md).
Names below are roles, not the disks' real identities.

| | L1. One copy of the family data, backed up | L2. The family data on a mirror |
|---|---|---|
| Family data (photos, databases, Nextcloud, documents) | one disk (the current small data disk, or the system disk if it is big enough) | **two** disks in a mirror: one more disk of the same size |
| Media library | the new disk, single | the new disk, single |
| Backup of everything, library included | the current large disk, single, receiving snapshots | the same |
| What a dying family-data disk means | the service stops until the last backup is restored (minutes of data lost, hours of work) | the service keeps running, the disk is replaced, nothing is lost |
| What it costs | nothing more than the new media disk | one more disk |
| Self-repair of a bad block | no: the backup repairs it | yes, automatically, on the data that matters most |

Both keep the rule that **a scrub that finds an error becomes an alert**, and both leave the library with exactly two local copies (the media disk and the backup disk), which is the intended trade-off.

## Consequences

- Whichever of B or C is chosen, **ext4 is left for the data disks**: a corrupted block there is returned as good data and backed up as good data.
- The media disk and the backup disk are scrubbed on a schedule, and a scrub that finds an error becomes an alert (phase 5).
- The system disk is a separate, smaller decision (it only holds what the flake recreates).
- The backup tool (ADR 0004) is chosen *after* this, because ZFS and btrfs bring their own snapshot replication, which covers the large-disk tier and leaves the file-level tools for the offsite tier.
