# 0005. Storage layout and filesystem

- **Status:** accepted (2026-10-01) with provisional parts: a two-SSD ZFS mirror, LUKS with a TPM if there is one; sizes await the inventory S1
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

## Mirror experiment (2026-10-01): what a failed member costs

The owner's layout uses a **mirror of two SSDs**, so the test that matters is not speed but what happens when a member dies. `lab/mirror-bakeoff.sh` (branch `exp/storage-mirror`) in the NixOS lab VM: a mirror of two 6 GB virtual disks, 400 MB written, a checksum list; plain and on LUKS.

| | btrfs RAID1 | ZFS mirror |
|---|---|---|
| 400 MB of one member overwritten with random bytes, then the scrub | **repaired**: "1 corrected", `csum` errors counted; all files identical; a second scrub clean | **repaired**: "scrub repaired 391M with 0 errors"; all files identical; a second scrub clean |
| The same on LUKS | identical | identical |
| A whole member lost (zeroed): **how the system says so** | **only error counters** (`btrfs device stats`: `corruption_errs 141056`); no "degraded" state | **`state: DEGRADED`**, and `zpool status -x` names the pool |
| Data while degraded | all files identical | all files identical |
| **Replacing the member** | 3 commands (`filesystem show`, `replace start`, `scrub start`) | **2 commands** (`zpool replace -w`, `zpool scrub -w`) |
| After the replacement | two devices, a scrub finds no errors, data identical | `state: ONLINE`, no errors, data identical |
| **Booting with one member missing** (one LUKS mapper closed) | **the mount is refused** unless the `degraded` option is given by hand | the pool **imports as DEGRADED** and serves the data |
| PostgreSQL 17, pgbench, 4 clients, 30 s (a toy: 6 GB virtual disks, repeated) | 156 to 215 tps | 325 to 421 tps (lz4 compression on) |
| Native monitoring of a failed member | none in NixOS (a separate exporter would be needed) | `services.zfs.zed`: events, including email |

The pgbench numbers are a toy and say only that neither is wildly slow; the repeated runs differ by more than the noise between runs of one candidate, in the same direction. The rest is qualitative and is the point:
**for a server that restarts without the owner, a mirror that refuses to mount with a missing member is a worse failure mode than one that comes up degraded and says so.**
(An earlier run of this script was thrown away: the lab disks were still mounted from an old experiment and every command had silently landed on the system disk; the script now stops when a mirror is not created.)

## Decision (2026-10-01)

Taken by the assistant on the owner's delegation ("tell me which"), with the owner's layout and constraints; reversible until the disks are bought.

- **Layout: L2 with the owner's disks.**
  - **Two SSDs in a mirror** for the system, the databases and the family's data. Sizes come from the inventory [S1](../gates/S1-storage-inventory.md) (budget up to about €250 for the pair).
  - The **16 TB disk receives backups of everything**, the media library included, written sequentially.
  - The **new 8 TB disk is the media library**, single (its second copy is the 16 TB disk).
  - The **2 TB disk (taken as SMR)** is **not** a mirror member and holds **no databases**: it is at most a secondary local copy written sequentially.
- **Filesystem: ZFS** (mirror on the two SSDs). Reasons, from the lab: it reports a lost member as DEGRADED and comes up degraded after a reboot, replacement is two commands, it has a native event daemon for notifications, and the toy run on PostgreSQL was faster. The offsite copy is a file-level Borg backup ([ADR 0007](0007-offsite-copy.md)), so ZFS's encrypted send to a remote is not needed and is not what tips it.
  Costs accepted: the kernel stays on a line ZFS supports (the G1 run was on such a kernel), and the cache is **capped** (the machine is also a media center).
- **Snapshots:** `services.sanoid` every 15 minutes on the datasets of the services ([ADR 0004](0004-backup.md)) and `services.syncoid` to the 16 TB disk.
- **Encryption of the disks:** a **LUKS layer under the pool with the key held in the machine's TPM** (systemd's native route; tested as a layer under both filesystems in the lab, without a TPM) **if S1 shows a TPM**; **otherwise no local encryption** (the owner's choice), relying on the offsite copy being encrypted.
  ZFS's own encryption is not used because it has no native TPM unlock.
- **S1 has been run** ([results](../gates/S1-results.md)): there is a TPM (so LUKS with the key in it), the data is about 165 GB, and the sizes and the number of SSDs are the owner's choice among A, B and C below.

## Update after S1 (2026-10-01): sizes, and what the SSDs cost

The inventory ([results](../gates/S1-results.md)) changes the sizing. The services' data is **about 165 GB** (Immich 34, iCloud photos 56, WebDAV 48, Syncthing 25) and grows about 4 GB a month; the databases are a few GB. The machine has a **TPM**; the 2 TB disk is **confirmed SMR** (and old: 3.6 years of power-on time, 1,475 command timeouts).
Second-hand SSDs are expensive today (about €200 for two of 1 TB, per the owner), and 1 TB each is more than the data needs. The options, from the same decisions:

| | Cost | What a disk failure means | Notes |
|---|---|---|---|
| **A. Two SSDs in a ZFS mirror** (the decision above) | the most | the service keeps running; replacement is two commands | 500 GB each is already three times the data; 1 TB only if the Incus VM disks (200 GB today) are to live on the SSDs too |
| **B. One SSD now, the second added later** (ZFS `copies=2` on the important datasets meanwhile) | about half of A, spent later when prices fall | **the server stops** until the SSD is replaced and restored from the 16 TB disk (hours; the owner accepted a few hours); data loss up to 15 minutes of files and 30 seconds of database | `zpool attach` turns the single disk into a mirror **online, with no rebuild**, so nothing is thrown away; `copies=2` makes ZFS **repair bad blocks** on a single disk (tested: ADR 0005's F2), not a dead disk |
| **C. No new SSD: the services on the large HDD, backups on the new 8 TB disk**, the system stays on the existing small SSD | nothing beyond the 8 TB | the large HDD dying stops the services until restored from the 8 TB copy | the two big disks hold **each other's backup** (services on one, media on the other); HDD latency is acceptable for a family-sized database (v0 already runs it on the SMR disk), but it is the slowest option |

In every option the **existing small SSD stays the system disk** (the system is rebuilt from the flake, so it needs no mirror), the **2 TB SMR disk leaves the services' role** (it holds nothing a database or a pool should depend on), and the TPM route for LUKS is open.

## A hardware finding that affects the layout (2026-09-30)

The disks seen from the live session (G1) are: a **small SATA SSD** as the system disk, the **large data disk**, and a **small 2.5-inch data disk**. The third disk is not installed yet.
The manufacturer's documentation for the small disk's model family says it is **SMR** (shingled magnetic recording): it absorbs bursts of writes in a cache and rewrites whole bands later,
so sustained **random writes are slow and their latency is unpredictable**. That is the profile of a database (WAL, checkpoints) and of a busy small-file workload, and of a ZFS resilver or a btrfs balance.
Today that disk holds the Docker data, Postgres included. Whether it really is SMR should be confirmed against its datasheet; if it is:

- **do not put the databases or ZFS data on it.** The system SSD (small, but the databases are) or a **CMR** disk are the candidates;
- it is fine as a **slow archive or a backup target that is written sequentially** (a `send`/`receive` of snapshots is sequential);
- the capacity planning in S1 has to include how much the databases need, to see whether they fit on the SSD.

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
