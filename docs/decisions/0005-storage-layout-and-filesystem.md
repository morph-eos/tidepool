# 0005. Storage layout and filesystem

- **Status:** accepted
- **Date:** 2026-09-30
- **Phase:** 2, Backup (it comes before the backup tool because the layout decides what the tool can rely on)

## Context

The previous system kept everything on ext4. ext4 does not notice a bit that flips on a disk: a block that goes bad is read back as if it were good, and then backed up as if it were good.

The storage is being reorganized around a reference setup of four kinds of disk:

- a small SSD for the operating system, which is rebuilt from the flake and needs no redundancy;
- an SSD of a few hundred GB to 1 TB for the databases and the live data of the services;
- a mid-size disk of about 2 TB, in the reference setup a shingled (SMR) drive, for the offsite repository, the disks of throwaway virtual machines and a NAS share;
- a large disk of about 16 TB for the Borg and pgBackRest repositories and the media library.

The media library does not go offsite: the space it would need, and its running cost, are out of proportion to its value. The data that cannot be recreated (photos, documents, databases) does go offsite, and is also covered by the local copy on the large disk ([ADR 0004](0004-backup.md)).

## Requirements

- Must: a corrupted block is noticed (an error, not wrong data). A periodic check (scrub) finds latent damage before a restore needs the data. It works on NixOS with the pinned kernel.
- Should: a way to back up to an untrusted remote without giving it the key; a modest memory footprint, since the machine is also a media center; self-repair where a second copy exists.
- Should not: parity RAID on btrfs (not considered safe), or any setup that needs someone to learn a storage stack before the data is safe.
- Cheap local snapshots were a requirement at first. They were dropped later in favour of the Borg repositories, see the decision.

## Options considered

| Option | What was done |
|---|---|
| A. ext4, as before (the baseline) | nothing |
| B. btrfs | a lab experiment |
| C. ZFS (OpenZFS 2.4 on the NixOS 26.05 kernel) | a lab experiment |

Criteria, in this order: whether it notices corruption and can repair it; the cost of snapshots and replication; operational fit on NixOS (memory, kernel coupling, tooling, what a restore looks like); whether a snapshot can go to a remote that is not trusted; effort and moving parts.

## Results

`lab/experiments/fs-bakeoff.sh` runs the same tests in a NixOS lab VM (4 cores, 5.6 GB of RAM, 6 GB disks, 20,000 files of 1 KiB). The corruption test writes a file, finds its first block on the raw device, overwrites 4 KiB of it behind the filesystem's back, and reads the file again.

| Test | A. ext4 | B. btrfs | C. ZFS |
|---|---|---|---|
| Corrupted block, one disk | silent: the read succeeds with wrong content | detected: I/O error, scrub reports it | detected: I/O error, scrub reports it |
| The same with a second copy on the disk (`data=dup`, `copies=2`) | not available | repaired from the copy | repaired from the copy |
| Snapshot of 20,000 files | 0.25 s for a hard-link copy, which is not a snapshot | 0.06 s | 0.04 s |
| Incremental replication after 1% of the files changed | rsync, 205 KB sent, but it walks every file | send/receive, 225 KB | send/receive, 5.3 MB (128 KiB records) |
| Memory | none | none to speak of | 90 MiB of cache (capped by default at about half the RAM, released under pressure) |

What the test does not show. The scale is a toy: it says whether each system notices, repairs and replicates, not how fast it is on a large disk, so the timings must not pick a winner. A single disk cannot repair itself without a second copy; for a data disk that copy is the backup, which replaces the file the filesystem has found. The "space held by a snapshot" figure is not comparable between btrfs and ZFS.

What the documentation adds (read, not run):

- ZFS encrypts per dataset and can send a snapshot encrypted to a remote that never sees the key. btrfs has no native encryption and is normally put on LUKS.
- btrfs is in the mainline kernel. ZFS is an out-of-tree module that on NixOS refuses to evaluate on a kernel it does not support, so the kernel stays on an LTS line. That fits pinning and constrains upgrades.
- btrfs fits a smaller memory budget; the ZFS cache can be capped.
- NixOS has `services.sanoid` and `syncoid` for ZFS, and `btrbk` for btrfs.

### Mirror experiment: what a failed member costs

The first layout used a mirror of two SSDs, so the question that matters is what happens when a member dies. `lab/experiments/mirror-bakeoff.sh`: a mirror of two 6 GB virtual disks, 400 MB written, plain and on LUKS.

| | btrfs RAID1 | ZFS mirror |
|---|---|---|
| 400 MB of one member overwritten, then a scrub | repaired, files identical | repaired, files identical |
| A whole member lost: how the system says so | only error counters, no "degraded" state | `state: DEGRADED`, and `zpool status -x` names the pool |
| Replacing the member | 3 commands | 2 commands |
| Booting with a member missing | the mount is refused unless `degraded` is given by hand | the pool imports as DEGRADED and serves the data |
| Monitoring a failed member | nothing native on NixOS | `services.zfs.zed`: events, including email |

PostgreSQL under pgbench ran faster on ZFS in this toy setup, but the runs differ by more than the noise, so it only says that neither is slow. The qualitative result is the point: for a server that restarts unattended, a mirror that refuses to mount with a missing member is a worse failure mode than one that comes up degraded and says so.

## Decision

### Filesystem

ZFS on the SSDs, where the data that matters lives. The large disk stays ext4: Borg and pgBackRest checksum their own data, and a flipped bit in a film is a glitch, not a loss. The reasons for ZFS are the ones measured above: checksums and scrub, a mirror that reports and boots degraded, two-command replacement, compression, and `zpool attach` to add a second SSD later without a rebuild. The costs accepted are that the kernel stays on a line ZFS supports and that the cache is capped.

The offsite copy is a file-level Borg backup, so ZFS's encrypted send is not needed and is not what tips the choice.

No scheduled snapshots and no replication of snapshots: the Borg repositories cover what a snapshot would undo.

Self-healing is deferred and done properly later, as a second SSD attached as a mirror, rather than with `copies=2` on chosen datasets, which would shrink a small disk. Until then ZFS detects corruption (a scrub, or a failed read, names the file) and the file comes back from Borg, or the database from pgBackRest.

### Disks and roles

| Disk | Role |
|---|---|
| SSD, a few hundred GB to 1 TB | single-disk ZFS pool: the databases and the live data of the services. Kept under about 80% full. |
| Small SSD | the system, rebuilt from the flake |
| Mid-size disk, about 2 TB (SMR) | the Borg repository prepared for the offsite copy, the disks of throwaway VMs, a local NAS share, overflow for static data |
| Large disk, about 16 TB (ext4) | the media library, the Borg repository of everything, the pgBackRest repository, an optional Time Machine partition |

Nothing on the mid-size disk is the only copy of anything that matters: the offsite repository is a second copy by definition, the NAS share is in the Borg repository of everything, and the VMs are replaceable. A VM that matters goes on the SSD. The sizing and how full each disk may get are in [the capacity page](../capacity.md).

A shingled disk absorbs bursts of writes in a cache and rewrites whole bands later, so sustained random writes are slow and their latency is unpredictable. That is the profile of a database, of a ZFS resilver and of a btrfs balance. It is fine as a slow archive or a backup target that is written sequentially, and it must not hold databases or ZFS data.

### Encryption of the disks

LUKS, with the key sealed in the machine's TPM.

| Disk | Encrypted | Why |
|---|---|---|
| SSD (live data) | yes | personal data in the clear |
| Mid-size disk | yes | the NAS share and the VMs |
| Small system SSD | yes | it holds the key that decrypts the repository's secrets ([ADR 0003](0003-secrets.md)); left plain, a thief with the disk and the repository could read them |
| Large disk | no | the media library, repositories that are encrypted already (Borg, pgBackRest), and a Time Machine partition that macOS encrypts |

What the TPM protects, and what it does not:

- A disk taken out and connected to another computer is protected: the key is sealed in the original machine's TPM.
- The whole machine booted by a thief is protected only if the boot chain is locked. A password at the login is not what stops the thief, because they do not need to log in: the TPM releases the key to whatever boots on that machine if the measurements it was sealed against still match. With Secure Boot off, the measurement usually used (PCR 7) is a constant, so an attacker's USB stick can get the key released ([systemd-cryptenroll](https://man.archlinux.org/man/systemd-cryptenroll.1)).
- What makes the stolen-machine case hold is Secure Boot enforced with a signed boot image, the boot loader's command-line editor off, and a firmware password. On NixOS the boot image is signed with its own keys through lanzaboote, with `sbctl` creating them.

The unattended-reboot trade-off is the real decision. A reboot by itself after a kernel update is only safe if the seal survives the update, so the key is sealed to PCR 7 only (the Secure Boot state and the key that signs the image), not to the kernel image, and there is no PIN at boot, since a PIN stops every unattended reboot.

That choice has a known cost. [A published attack](https://oddlama.org/blog/bypassing-disk-encryption-with-tpm2-unlock/) needs the whole machine and about ten minutes: the thief takes the disk out, writes a fake LUKS partition with the same identifiers and a malicious init, puts it back and boots. The legitimate signed chain asks the TPM for the key, the unlock of the fake volume fails, the initrd mounts the fake system, and its init asks the TPM for the real key, which the TPM releases because the boot chain measured the same. The defences are a TPM PIN or binding the key to the measured volume key (PCR 15).

Two designs were compared:

- A. TPM only, hardened (PCR 7, no console login, emergency shell off, IOMMU on, Thunderbolt off, firmware password). Unattended reboots work. A casual burglar gets nothing; a skilled one with the whole machine might.
- B. TPM with a PIN. The stolen machine is protected, but every reboot waits for the PIN, so the automatic reboot of [ADR 0018](0018-deploys-by-the-server.md) cannot work.

I chose A. The realistic threat is an opportunistic burglar, the attack needs the whole machine and some preparation, and a PIN would make every weekly reboot a manual one. I accept the residual risk, a skilled and targeted thief with the whole machine. I did not adopt PCR 15 binding: it needs a policy that depends on the order in which the volumes open, and the simple form of it is a redesign, left for later if the risk is ever to be lowered.

Tried in the lab (`lab/experiments/tpm-u21.sh`, with UEFI, a Secure Boot firmware and an emulated TPM 2.0): LUKS under the root, the ZFS pool and the mid-size disk; lanzaboote with its own keys, enrolled by the firmware; each volume sealed to PCR 7. The machine boots by itself in about 30 s. A kernel change (6.18 to 6.12) and a reboot left PCR 7 unchanged and the disks opened by themselves. The disks behind another TPM asked for the passphrase. Another system started on the machine, such as the installer, changed PCR 7 and the TPM refused. Two findings: a firmware reset did not matter, because lanzaboote's automatic enrollment put the same keys back; and `sbctl` has to be installed before Secure Boot is switched on, since the first lanzaboote switch stops without keys. Not tried in the lab: the swap attack, a PIN. The steps are in [the encryption runbook](../encryption-runbook.md).

### No dedicated media disk

I considered a separate disk for the media library, so that the large disk could hold its second copy, and did not buy one. The library stays on the large disk in one copy.

| Option | Verdict |
|---|---|
| A. Buy a dedicated media disk | not now |
| B. Buy nothing; the large disk stays ext4 and keeps the media | chosen: no conversion, no disk to move the data meanwhile, no cost |
| C. A smaller used disk sized to the library | not needed while the large disk has room |
| D. A second copy only of what is hard to replace | what cannot be re-obtained goes in the Borg repositories or the offsite copy, not in the media library |

Capacity is not a reason to buy now. A disk fails in a given year with a probability of the order of 1 to 2 percent (published fleet statistics), and the data that matters does not depend on this disk. A failing disk is replaced, not repaired, and that works only while it still reads, so it relies on a SMART alert ([ADR 0012](0012-observability.md)): a disk replaced on a warning loses nothing, and one that dies suddenly loses the media only, which is then re-obtained. When the library outgrows the disk, another is added; nothing in the design depends on having it now.

### Memory

Whether 16 GB is enough was settled with a peak budget, not a purchase. Estimated peaks: the system and desktop 1.5 GB; the ZFS cache, capped at about 3 GB; PostgreSQL for three databases about 1.5 GB; Immich with a machine-learning burst about 3.5 GB; Jellyfin with a transcode about 1.5 GB; Nextcloud and the rest about 1 GB; the Borg and pgBackRest jobs about 1 GB. That is about 13 GB without virtual machines, and a 4 GB test VM brings it to about 17 GB, which swap absorbs. So the memory is enough if the ZFS cache is capped and the VMs stay modest. Swap is zram, plus a swap file only on the SSD, never on the shingled disk or on a ZFS volume. The memory pressure counters are what to watch ([ADR 0012](0012-observability.md)).

## How the decision changed

1. The filesystem tests: ext4 returns a damaged block as good data; btrfs and ZFS detect and repair; on a mirror ZFS reports and boots degraded.
2. First proposal: two SSDs in a ZFS mirror, snapshots every 15 minutes replicated to the large disk, LUKS on three disks.
3. The inventory showed that the services' data is small (about 165 GB, growing a few GB a month) and that a second SSD is not needed on day one. The options were:

| | What a disk failure means |
|---|---|
| A. Two SSDs in a ZFS mirror | the service keeps running; replacement is two commands |
| B. One SSD now, the second added later | the server stops until the SSD is replaced and restored from the large disk (hours); `zpool attach` turns the single disk into a mirror online later |
| C. No new SSD: the services on the large disk | the large disk dying stops the services until restored; the slowest option |

   I chose B, with the roles above.
4. I dropped snapshots: Borg already holds what a snapshot would undo, and snapshots cost space.
5. The large disk was first to be encrypted; with snapshots replaced by Borg it holds encrypted repositories, the media and an encrypted Time Machine partition, so it is not.
6. I deferred self-healing to a real second SSD.

## Consequences

- ext4 is left for the data disks: a corrupted block there is returned and backed up as good data. The backup tools do not depend on ZFS features ([ADR 0004](0004-backup.md)), so the filesystem could change later without changing them.
- A scrub that finds an error becomes an alert, on every pool.
- What a failed disk means:

| Disk dies | Effect | Recovery |
|---|---|---|
| SSD (live data) | the services stop until it is replaced | the database from the pgBackRest repository (about 30 seconds lost), the files from the Borg repository of everything (up to one or two hours lost) |
| Large disk | no service stops; the media library (one copy) and the local repositories are gone | the repositories are rebuilt from the live data and the offsite copy is untouched; the media is re-obtained. Replace the disk on a SMART warning |
| Mid-size disk | the VMs and the NAS share are gone | the share from the Borg repository of everything; the VMs are replaceable; the offsite repository is rebuilt from the live data |
| System SSD | the server does not boot | rebuild from the flake; the secrets need the age key, kept off the machine |

- Revisit when a second SSD is added (a mirror by `zpool attach`).
