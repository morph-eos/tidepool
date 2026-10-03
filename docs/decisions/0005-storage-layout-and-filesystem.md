# 0005. Storage layout and filesystem

- **Status:** accepted (2026-10-01), reviewed the same day for coherence: one new SSD of about 500 GB (single-disk ZFS pool, a mirror later), the small SSD for the system, the 2 TB disk for the offsite repository, the VMs and the NAS share, the 16 TB disk for the repositories of everything, the 8 TB disk for the media; LUKS with the TPM on the SSDs and the 2 TB disk
- **Date:** 2026-09-30
- **Phase:** 2, Backup (it comes before the backup tool because the layout decides what the tool can rely on)
- **Update 2026-10-03 (reboots):** the owner allowed the server to **reboot by itself after a new kernel** ([ADR 0018](0018-deploys-by-the-server.md)). That is only safe if the TPM seal **survives a kernel update**: **seal the key to PCR 7 only** (the Secure Boot state and the key that signs the boot image, which lanzaboote keeps the same), **not to the kernel image or the boot-loader files** (the "ideally also to the kernel image" below would make every kernel update ask for the passphrase), and **no PIN at boot** (it stops every unattended reboot). The Secure Boot enforcement, the editor off and the firmware password still make the stolen-machine case hold. **Not tried:** the first kernel update on the real machine must be rehearsed at the console (`nixos-rebuild boot`, then a reboot).
- **Correction the same day (the owner's objection): without a PIN the stolen-machine case does NOT hold against a determined thief.** [A published attack](https://oddlama.org/blog/bypassing-disk-encryption-with-tpm2-unlock/) needs the whole machine and about ten minutes: the thief takes the disk out, writes a **fake LUKS partition with the same identifiers** and a malicious init, puts it back and boots; the legitimate signed boot chain **asks the TPM for the key**, the unlock of the fake volume fails, the initrd mounts the fake system, and **its init asks the TPM for the real key**, which the TPM releases because the boot chain measured the same. The author's own verdict on unattended TPM-only unlock is that it is not safe against a thief with the entire machine; the defences are a **TPM PIN**, or **binding the key to the measured volume key (PCR 15)** and checking it before anything runs. So the choice is a real one and **open**: **(A) TPM only, hardened** (PCR 7 and the volume key, no console login, emergency shell off, IOMMU on, Thunderbolt off, firmware password): unattended reboots work, and a casual burglar gets nothing, but a skilled one with the whole machine might; **(B) TPM with a PIN**: the stolen machine is protected, but every reboot waits for the PIN (typed at the console, or over ssh in the initrd), so **the automatic reboot of [ADR 0018](0018-deploys-by-the-server.md) cannot work**. None of this was tried in the lab.
- **Update 2026-10-03:** the NAS share decided here is **built** (`modules/nas.nix`, [ADR 0017](0017-version-watch-push-and-nas.md)): the share on the 2 TB disk, its path and the Samba users' database in the Borg job of everything, an optional Time Machine share on the 16 TB disk's partition (not backed up).

## Context

v0 keeps everything on ext4, which gives no protection against a bit that flips on a disk: a block that goes bad is read back as if it were good, and then backed up as if it were good.
The storage is about to be reorganized: a **third disk for the media library**, and the current **large disk as the backup target for everything**, library included
(the owner's answers in [ADR 0004](0004-backup.md)). The library does **not** go offsite: the disk that would hold it, and its running cost, are out of proportion to its value.
The family's data (photos, documents, databases) does go offsite, and is also covered by the local copy on the large disk.

## Requirements

- **Must:** a corrupted block is **noticed** (an error, not wrong data); a periodic check (scrub) finds latent damage before a restore needs the data;
  works on NixOS with the pinned kernel; cheap local snapshots, so a mistaken delete or an overwrite is undone in seconds (**a requirement at the time; the owner later chose to cover it with the Borg repositories instead, see the decision**).
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

The first layout used a **mirror of two SSDs** (later reduced to one SSD now and a mirror when a second is bought), so the test that matters is not speed but what happens when a member dies, now and when the second SSD is added. `lab/mirror-bakeoff.sh` (branch `exp/storage-mirror`) in the NixOS lab VM: a mirror of two 6 GB virtual disks, 400 MB written, a checksum list; plain and on LUKS.

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

## Decision (final state, 2026-10-01)

How each point came about is under "How the decision changed" below.

**Disks and roles**

| Disk | Role |
|---|---|
| **New SSD, about 500 GB** (the owner buys it; a single-disk ZFS pool for now) | the **primary**: the databases and the live data of the services (Immich, Nextcloud, Vaultwarden, Syncthing, the notes, WebDAV). Kept under about 80% full. |
| **Existing small SSD (119 GB)** | the **system**, rebuilt from the flake |
| **2 TB disk (SMR, 3.6 years old)** | the **Borg repository prepared for the offsite** (selected family data; [ADR 0004](0004-backup.md), [0007](0007-offsite-copy.md)); the **disks of the Incus virtual machines or whatever replaces it** (mostly throwaway tests where an SSD is wasted; **a VM that matters goes on the SSD**); a **local NAS share**; the **overflow** for static data (music, video) if the SSD fills |
| **16 TB disk** (stays ext4, no conversion) | the **media library** (one copy), the **Borg repository of everything**, the **pgBackRest repository** and the **Time Machine partition** (kept for now; encrypted by macOS, by the user of that backup) |
| **8 TB disk** | **not bought** (the owner, 2026-10-01); a disk is added when the library outgrows the 16 TB disk |

Nothing on the 2 TB disk may be the only copy of anything that matters: the offsite repository is a second copy by definition, the NAS share is in the Borg repository of everything, and the VMs are replaceable. The ZFS-versus-LVM choice for Incus's storage belongs to phase 6.

**Filesystem: ZFS on the SSDs**, where the family's data lives. The 16 TB disk **stays ext4** (the owner, 2026-10-01): Borg and pgBackRest checksum their own data, and a flipped bit in a film is a glitch, not a loss. The 2 TB disk's filesystem goes with the choice for Incus in phase 6. From the lab: it reports a lost member as DEGRADED and comes up degraded after a reboot, replacement is two commands, it has a native event daemon for notifications (`services.zfs.zed`), and the toy run on PostgreSQL was faster. Costs accepted: the kernel stays on a line ZFS supports (the G1 run was on such a kernel) and the cache is **capped** (the machine is also a media center).
The offsite copy is a file-level Borg backup, so ZFS's encrypted send is not needed and is not what tips it.

**No scheduled snapshots, no replication of snapshots.** The Borg repositories cover what a snapshot would undo ([ADR 0004](0004-backup.md)). ZFS stays the choice because the reasons above do not depend on snapshots: checksums and scrub, a mirror that reports and boots degraded, two-command replacement, compression, and `zpool attach` to add the second SSD later.

**Self-healing: deferred, and done properly later.** The owner does not want a partial scheme (`copies=2` on chosen datasets) that shrinks the 500 GB disk, and prefers the real one: **a second SSD of about 500 GB attached as a mirror** (`zpool attach`, online, no rebuild) when it can be bought; that also survives a dead disk. Until then ZFS **detects** corruption (a scrub, or a failed read, names the file) and the file is restored from Borg, or the database from pgBackRest.

**Encryption of the disks (LUKS, the key in the machine's TPM)**

| Disk | Encrypted | Why |
|---|---|---|
| Primary SSD | yes | personal data in clear |
| 2 TB disk | yes | the NAS share and the VMs |
| Small system SSD | **yes** (decided with the owner, 2026-10-01) | it holds the key that decrypts the secrets of the repository ([ADR 0003](0003-secrets.md)); left plain, a thief with the disk and the repository's secrets could read them |
| 16 TB disk | **no** (the owner, 2026-10-01) | the media library (nothing personal), encrypted repositories (Borg, pgBackRest), and a Time Machine partition encrypted by macOS |

What the TPM protects, and what it does not (the owner asked: if every login needs a password, can someone who steals the whole machine still read the disks?):
- **A disk taken out and connected to another computer: protected.** The key is sealed in the original machine's TPM, and another computer has no way to release it.
- **The whole machine, booted by the thief: protected only if the boot chain is locked.** A password at the login (SSH or the screen) is **not** what stops the thief, because they do not need to log in: the TPM releases the key to whatever boots on that machine **if the measurements it was sealed against still match**. With **Secure Boot off**, the measurement the key is usually sealed to (PCR 7) is a constant "Secure Boot disabled" value, so **an attacker's USB stick, or a changed kernel command line, can get the key released** ([systemd-cryptenroll, Arch manual](https://man.archlinux.org/man/systemd-cryptenroll.1); [a demonstration](https://oddlama.org/blog/bypassing-disk-encryption-with-tpm2-unlock/); general knowledge, **not tested here**).
- **What makes the owner's reasoning true** is therefore: **Secure Boot enforced with a signed boot image** (the key sealed to it, ideally also to the kernel image), the boot loader's command-line editor disabled, and a firmware password; then the thief can only boot the intended system, and the login password protects the data. **Or a PIN at boot** (`--tpm2-with-pin`), which stops unattended reboots. A third way, for later, is unlocking over the home network from another device (Tang with Clevis), so a machine carried out of the house stays locked.
- **Where this stands (2026-10-01):** Secure Boot is **already enabled in the firmware** of the current server. On the NixOS system the boot chain has to be signed with **the owner's own keys**: the usual way is **lanzaboote** (an external flake input, pinned like the others) with `sbctl` creating the keys; it signs the boot image, keeps `systemd-boot`'s command-line editor off, and lets the LUKS key be sealed to it ([the lanzaboote quick start](https://github.com/nix-community/lanzaboote/blob/999c0cb03f748fe311bca78961dbf0562dc91659/docs/QUICK_START.md); read, **not tried here**). The firmware password is the owner's to set. Until that chain exists on NixOS, the encryption protects against the **disk-only** cases (a stolen, returned or discarded disk), not a stolen machine. This is host-phase work.

## The 8 TB media disk (decided 2026-10-01: not bought now)

The plan had bought an **8 TB disk** (used, about €140) for the media library, so that the 16 TB disk would hold its second copy. The owner, after weighing it, **chose to buy nothing now** (option B below): the library stays on the 16 TB disk in one copy.

| Option | Verdict |
|---|---|
| A. Buy the 8 TB disk | not now |
| **B. Buy nothing now; the 16 TB disk stays ext4 and keeps the media** | **chosen**: no conversion, no disk to move the data meanwhile, no cost |
| C. A smaller used disk sized to the library | not needed while the 16 TB disk has room |
| D. A second copy only of what is hard to replace | what cannot be re-obtained goes in the Borg repositories or the offsite copy, not in the media library |

Why it holds, from the facts:
- **Capacity is not the reason to buy now**: the 16 TB disk's data partition has 11.8 TB with 3.1 TB used. When the library outgrows it, another disk is added (the owner expects to grow it past 4 TB).
- **The risk is small and the loss is replaceable**: a disk fails in a given year with a probability of the order of 1 to 2 percent (published fleet statistics; general knowledge); the 16 TB disk has about 9,600 hours and a clean SMART report; the family's data does not depend on it (SSD, the offsite repository on the 2 TB disk, the offsite copy).
- **A failing disk is replaced, not repaired**: the owner's plan is to buy another disk when this one fails and copy. **That works only while the disk still reads**, so it relies on a SMART alert (phase 5): a disk that is replaced on a warning loses nothing; one that dies suddenly loses the media only, which is then re-obtained.
- **The 8 TB disk stays an upgrade for later** (the owner has other purchases first, the SSD above all); nothing in the design depends on having it.
- The owner keeps a personal library on purpose: ownership matters to him, in a world where streaming titles disappear, even for things he rarely rewatches, and the family may watch the same titles later.

What Jellyfin's database says about the library (read-only, aggregated, no titles; Jellyfin has run since February 2026, so 7.5 months of history): **35 films (1,095 GB, about 31 GB each) and 299 episodes (313 GB)**, 3,771 music tracks, 6 users; **91 of the 334 films and episodes were played at least once (27% by count, 48% by size, 672 GB)**. The space is dominated by a few very large files: at that size, a library of 130 films is already 4 TB, so the growth depends on how large the files are as much as on how many (a re-encode of what is not a favourite would shrink it several times; the hardware transcoding check G2 is pending).

## Memory: is it enough? (2026-10-01)

Measured on the current server (read-only): **4.7 GiB in use**, no memory pressure at all (the kernel's pressure counters are zero), the 16 GB swap file and the zram swap unused. The containers add up to about **2.6 GiB** (Immich's server 0.9, Jellyfin 0.4, the Immich and Nextcloud databases about 0.35, Nextcloud 0.2, Syncthing 0.15, the Immich machine learning 0.2 while idle) and the desktop session about **1.2 GiB**; the two Incus VMs are stopped. The server had been up only 12 hours, so **peaks are not measured**.

What the new system adds, as a peak budget (estimates): the system and desktop 1.5 GB; the **ZFS cache, to be capped at about 3 GB** (it shrinks under pressure, but a cap keeps it predictable on a media center); PostgreSQL 17 for three databases about 1.5 GB; Immich with its machine-learning burst about 3.5 GB; Jellyfin with a transcode about 1.5 GB; Nextcloud and the rest about 1 GB; the Borg and pgBackRest jobs about 1 GB. That is **about 13 GB without virtual machines**, and a test VM of 4 GB makes it about 17 GB, which the swap absorbs.
**Verdict: the memory is enough for the planned system** if the ZFS cache is capped and the VMs stay modest. It is **not a purchase to make now**; add memory only if the first weeks show pressure (the memory pressure counters are the thing to watch, phase 5) or if several VMs run at once. Swap: **zram** (declared in NixOS), and a swap file only on the SSD, never on the SMR disk or on a ZFS volume. Whether there is a free memory slot is unknown (it needs root to read).

## How the decision changed

1. **The filesystem tests** (above): ext4 returns a damaged block as good data; btrfs and ZFS detect and repair; on a mirror ZFS reports and boots degraded.
2. **First recommendation:** two SSDs in a ZFS mirror, with snapshots every 15 minutes replicated to the 16 TB disk and LUKS on three disks.
3. **After S1** (the services' data is only 165 GB; second-hand SSDs are expensive) the options below were offered, and the owner chose **B with his own roles** for the disks.
4. **The owner then dropped the snapshots** (his argument, accepted: Borg already holds what a snapshot would undo, and snapshots cost space) and **deferred self-healing** to a real second SSD.
5. **Encryption:** the 16 TB disk was first to be encrypted; with snapshots replaced by Borg it holds encrypted repositories, the media and an encrypted Time Machine partition, and the owner decided to skip it.
6. **The 8 TB disk** was first to hold the media with the 16 TB disk as its second copy; the owner decided against buying it now, and the 16 TB disk stays ext4.

### The options offered after S1

The inventory ([results](../gates/S1-results.md)) changes the sizing. The services' data is **about 165 GB** (Immich 34, iCloud photos 56, WebDAV 48, Syncthing 25) and grows about 4 GB a month; the databases are a few GB. The machine has a **TPM**; the 2 TB disk is **confirmed SMR** (and old: 3.6 years of power-on time, 1,475 command timeouts).
Second-hand SSDs are expensive today (about €200 for two of 1 TB, per the owner), and 1 TB each is more than the data needs. The options, from the same decisions:

| | Cost | What a disk failure means | Notes |
|---|---|---|---|
| **A. Two SSDs in a ZFS mirror** (the first recommendation) | the most | the service keeps running; replacement is two commands | 500 GB each is already three times the data; 1 TB only if the Incus VM disks (200 GB today) are to live on the SSDs too |
| **B. One SSD now, the second added later** (ZFS `copies=2` on the important datasets meanwhile) | about half of A, spent later when prices fall | **the server stops** until the SSD is replaced and restored from the 16 TB disk (hours; the owner accepted a few hours); data loss up to the file-backup interval (then planned as 15 minutes, now one to two hours of Borg) and 30 seconds of database | `zpool attach` turns the single disk into a mirror **online, with no rebuild**, so nothing is thrown away; `copies=2` would make ZFS **repair bad blocks** on a single disk (tested: F2 above), not a dead disk; the owner later deferred it |
| **C. No new SSD: the services on the large HDD, backups on the new 8 TB disk**, the system stays on the existing small SSD | nothing beyond the 8 TB | the large HDD dying stops the services until restored from the 8 TB copy | the two big disks hold **each other's backup** (services on one, media on the other); HDD latency is acceptable for a family-sized database (v0 already runs it on the SMR disk), but it is the slowest option |

In every option the **existing small SSD stays the system disk** (the system is rebuilt from the flake, so it needs no mirror), the **2 TB SMR disk leaves the services' role** (it holds nothing a database or a pool should depend on), and the TPM route for LUKS is open.


### A hardware finding that affects the layout (2026-09-30; the SMR is now confirmed)

The disks seen from the live session (G1) are: a **small SATA SSD** as the system disk, the **large data disk**, and a **small 2.5-inch data disk**. The third disk is not installed yet.
The manufacturer's documentation for the small disk's model family says it is **SMR** (shingled magnetic recording): it absorbs bursts of writes in a cache and rewrites whole bands later,
so sustained **random writes are slow and their latency is unpredictable**. That is the profile of a database (WAL, checkpoints) and of a busy small-file workload, and of a ZFS resilver or a btrfs balance.
Today that disk holds the Docker data, Postgres included. It is **confirmed SMR** against the manufacturer's documentation, and it is old (3.6 years powered on, 1,475 command timeouts):

- **do not put the databases or ZFS data on it.** The system SSD (small, but the databases are) or a **CMR** disk are the candidates;
- it is fine as a **slow archive or a backup target that is written sequentially** (a `send`/`receive` of snapshots is sequential);
- the capacity planning in S1 has to include how much the databases need, to see whether they fit on the SSD.


### The first layout proposals (superseded by the decision above)

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

- **ext4 is left for the data disks**: a corrupted block there is returned as good data and backed up as good data.
- **A scrub that finds an error becomes an alert** (phase 5), on every pool: the primary SSD, the media disk, the 16 TB disk and the 2 TB disk.
- **What a failed disk means:**

| Disk dies | Effect | Recovery |
|---|---|---|
| Primary SSD | the services stop until it is replaced | the database from the pgBackRest repository (about 30 seconds lost), the files from the Borg repository of everything (up to one or two hours lost); hours of work |
| 16 TB disk | no service stops; the **media library (one copy)** and the local repositories are gone | the repositories are rebuilt from the live data and the offsite copy is untouched; the media is re-obtained. **Replace the disk on a SMART warning**, copying while it still reads (this needs the alert of phase 5); a sudden failure loses the media only |
| 2 TB disk | the VMs and the NAS share are gone | the share from the Borg repository of everything; the VMs are replaceable; the offsite repository is rebuilt from the live data |
| System SSD | the server does not boot | rebuild from the flake; the secrets need the age key from Proton Pass or paper |

- **The backup tools do not depend on ZFS features** ([ADR 0004](0004-backup.md)): pgBackRest and Borg are file-level, so the filesystem could change later without changing them.
- **Revisit** when the second SSD is bought (a mirror by `zpool attach`), and when Secure Boot is set up on NixOS.
