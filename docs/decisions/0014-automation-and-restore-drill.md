# 0014. Automation: proving that the host rebuilds from nothing and that a restore brings everything back

- **Status:** accepted (2026-10-06, at the owner's request that the statuses be brought up to date): the lab proof passed on 2026-10-02 and again on the final tree on 2026-10-06; the two open questions are answered below
- **Date:** 2026-10-02
- **Phase:** 7, Automation

## Context

Every earlier phase decided a piece and proved it **alone**: the host layer, the storage, the databases, the backups, the services, the edge, the VMs, the alerts. v0 was never rebuilt from an empty disk, and none of the phases so far showed that **the pieces together** can be put back from nothing. This phase answers "how is *rebuild from scratch* proven on every change?" and runs the **full restore drill** that [ADR 0004](0004-backup.md) and the backup ADRs left open: a database and its files brought back **to the same moment**, on a rebuilt machine.

To prove it, the experiments' modules had to become **one system**. Until now `reengineering` held no `nixos/` directory: the NixOS code lived on the experiment branches, in lab form. This phase builds the integrated flake (`nixos/`), which is what the real host will be.

## Requirements

- **Must:** a blank machine becomes the whole system from the repository and the age key, with **no manual step inside the flake's scope** (the first-time provisioning of the two large backup disks is outside it and written down); the backups **survive the loss of the system disk and of the SSD**; a restore brings back the databases and the files **to the same moment**, and **checks, not eyes, say whether it worked**; the proof runs unattended and ends in PASS or FAIL; times are recorded.
- **Should:** every change is checked cheaply; the real host and the lab host share the code and differ in values; the steps of the lab proof are the steps of the runbook for the real machine.
- **Won't:** pretend the lab shows the real hardware (the GPU, the TPM, Secure Boot, the SMR disk, 165 GB of data, the home uplink).

## What was built

`nixos/`: **one flake, two hosts, the same modules.**

| Module | What it holds | Decided in |
|---|---|---|
| `base` | admin user and key, SSH, fail2ban, crash dump, time, **Podman**, the firewall on with forward filtering | [0002](0002-host-as-code.md), [0013](0013-vms-and-containers.md) |
| `storage` | **disko**: the system disk and the SSD's ZFS pool with its datasets, declared; the two large disks only mounted | [0005](0005-storage-layout-and-filesystem.md) |
| `secrets` | sops-nix: every secret by name, none in the Nix store | [0003](0003-secrets.md) |
| `database` | PostgreSQL 17 and pgBackRest (the repository on the 16 TB disk) | [0004](0004-backup.md), [0006](0006-postgresql-version-and-immich.md) |
| `backup` | Borg, two repositories, every hour | [0004](0004-backup.md), [0007](0007-offsite-copy.md) |
| `services` | Nextcloud, Vaultwarden, Syncthing, WebDAV through nginx, smartd; Immich and Jellyfin as Podman containers pinned by digest | [0011](0011-services.md) |
| `edge`, `vpn` | nginx and ACME (DNS challenge on the real host), WireGuard | [0008](0008-edge.md), [0009](0009-remote-access-vpn.md) |
| `vms`, `publish-gate` | Incus with its two pools, and the publication gate | [0010](0010-vm-service-exposure.md), [0013](0013-vms-and-containers.md) |
| `observability` | Prometheus and Alertmanager: mail through Brevo and the heartbeat on the real host, sinks in the lab | [0012](0012-observability.md) |

The **lab host** (`hosts/lab`) differs from the **real host** (`hosts/tidepool`) only in values and small stand-ins: a test CA (Pebble), a mail sink and a heartbeat sink, **Immich's machine learning and Jellyfin switched off** (memory), no GPU device, BIOS boot. The real host's private values (domain, disks by serial, VPN peers, admin key) are meant to come from the private repository ([ADR 0003](0003-secrets.md)); the repository holds an **example** that builds.

## The proof

`lab/restore-drill.sh all` against a lab VM with **four disks**: the system disk, an SSD for the ZFS pool, a stand-in for the **16 TB** disk and one for the **2 TB** disk.

1. **Seed:** 12 generated pictures into Immich, files into Nextcloud and WebDAV, a marker row in each database, an instance on the 2 TB pool of Incus; the first backups (pgBackRest full, both Borg repositories). Then more data, **the moment T_GOOD is written down**, and the second backups.
2. **Damage after T_GOOD:** three Immich assets **deleted for good** (their original files go too), a Nextcloud file and a WebDAV file deleted, a "damage" marker in each database; the WAL after T_GOOD reaches the repository.
3. **Disaster:** the VM is stopped and **the system disk and the SSD are replaced by blank ones**; the two large disks stay.
4. **Rebuild from the flake** on the blank machine: the layout from disko, `nixos-install`, the age key.
5. **Restore** on the empty machine: services stopped, `/srv/data` emptied, the files from the first Borg archive **at or after T_GOOD**, the database **to T_GOOD** by pgBackRest, Incus checked, services started.
6. **Verify:** 14 checks (below).

## Results

Lab host: 4 vCPUs, 8 GB, nested virtualization (the same limits as [ADR 0013](0013-vms-and-containers.md)). Passed on the **fourth full run** (the two earlier ones and a third, which ran into a mistake of mine in the lab, found the defects listed below).

| Measure | Result |
|---|---|
| **Rebuild from blank to a booted system** | **547-559 s** (**930 s** once, on a slow day of the lab's link; the installer's downloads now have a stall timeout, after one hung for 38 minutes) (`nixos-install` 447-468 s of it): the system disk and the SSD wiped and made by disko, **the two large disks untouched** |
| **Restore to the end of the checks** | **167-169 s** (240 s on the run with the hourly archives and the longer waits, which also passed) from the first command on the rebuilt machine (services start, 87 files from Borg, the database restored in **20-21 s**, the rest) |
| Immich | **18 assets, as at T_GOOD** (the three deleted afterwards are back) and **all 18 originals are served**: the database and the files came back to the same moment |
| Databases | the markers of Immich, Vaultwarden and Nextcloud read `before, after-backup1`: **no `damage`** |
| Nextcloud, WebDAV | the five files as at T_GOOD, **the deleted ones back with their content** |
| Vaultwarden | answers, and **its RSA key, which is outside the database, is the one that was backed up** |
| Incus | the instance on the surviving 2 TB pool is back, **running**, its file intact |
| `borg check --verify-data` | both repositories pass |
| `pgbackrest check` | archiving works after the restore |
| Units failed at the end | **0** |
| `nix flake check` | both hosts evaluate and build: **24 s** with a warm store |
| Memory of the integrated stack in the lab | **2.1 GB used of 7.8 GB** (without Immich's machine learning and Jellyfin; the ZFS cache capped at 768 MiB) |

### What the drill found and what was done about it

| Defect | How it showed | Fix |
|---|---|---|
| **`zfs-mount.service` failed on every boot**: the datasets were mounted by fstab **and** by ZFS | a failed unit, which the alerts would report forever | the datasets are `legacy` mountpoints, mounted by systemd only (`storage.nix`) |
| **The surviving 2 TB disk broke the declared Incus pool**: a rebuilt Incus (empty database) refused to create the pool over a non-empty folder, and its preseed unit stayed failed; **`incus admin recover` needs the declared network to exist first** and is interactive | the second full run | **Incus's state lives on the 2 TB disk** (`/var/lib/incus` is a bind mount of a folder there): a rebuilt host finds its instances as they were; no manual recovery. The folder is made at first-time provisioning |
| The database was fine, but **`PostgresArchiveFailing` fires after a rebuild** until the first backup runs (archiving fails while the stanza does not exist) | the alerts on the rebuilt host | expected: it is a true signal. The runbook ends with a backup. The rule stays |
| Nextcloud's admin is **`root`** by default in the module | the checks got 401 | the drill uses that name; the option `adminuser` is the way to change it |
| sops-nix **checks the secrets file of the example host** at build | `nix flake check` failed | the example host's file is a stand-in with the right keys |
| **The backup named the wrong folder for Vaultwarden** (`/var/lib/bitwarden_rs`; the module keeps its data in `/var/lib/vaultwarden`): its RSA key was **not in any backup**, hidden by `failOnWarnings = false`; the drill passed because its database is in PostgreSQL | found while testing the backup checks ([ADR 0015](0015-backup-verification.md)) | the path is fixed, and the drill now compares the key's checksum before and after |
| The drill's own seed step **raced the Borg jobs**: they are not `oneshot` units, so `systemctl start` returns at once | an empty "archive after T_GOOD" in the report | the drill waits for them to finish |
| A test of my own: uploads with `curl -T -` created **empty** Nextcloud files | the first content check failed | the drill uploads from files and checks the content |
| An in-place `nixos-rebuild switch` ends with exit 4 and "user activation failed" in the lab (no user session bus) | the lab's switch | cosmetic; the installer path is unaffected |

## What the lab stood in for, and what it does not show

- **Small data:** a few tens of MB of photos, a 190 MB database repository. The **timings scale with the real 165 GB**: the restore of the files and the first Borg run are not measured at that size, nor the 200 GB offsite upload.
- **Not in the integrated lab host:** Immich's **machine learning** and **Jellyfin** (a 2.5 GB image) are declared and evaluate, but did not run; **no GPU**.
- **Boot and disks:** BIOS boot with grub and an ext4 root. The real layout (**UEFI, lanzaboote, LUKS with the TPM**, [ADR 0005](0005-storage-layout-and-filesystem.md)) is **not tried**; the mechanism (disko from the flake) is.
- **Certificates, mail and the heartbeat:** Pebble, a mail sink and a heartbeat sink. The real **DNS challenge**, **Brevo** and **Healthchecks.io** are untested on the integrated host.
- **The offsite copy:** **no restore from the offsite** was run (Hetzner or Proton Drive); only the 2 TB offsite-bound Borg repository is verified. A restore from a **Hetzner snapshot** (the `/.zfs/snapshot` path) is untested.
- **The private repository** (`vars`) that supplies the real values is wired as a stand-in only.
- The Incus **`fast` pool** (ZFS on the SSD): an instance there is lost with the SSD, by design; not exercised.
- The restore of files uses Borg's names for users; whether the **numeric user ids** of the dynamic NixOS users match across a reinstall was not examined (it worked here because Borg restores by name).

## Criteria, in this order

1. **The proof is a check, not a read:** pass or fail, repeatable, from the repository.
2. **The backups survive what they are meant to survive** (system disk and SSD lost), measured.
3. **No manual step in the flake's scope**; the ones outside it are written down.
4. **Cost of repeating it.**

## Proposed decision

**Three layers of proof, all from the repository.**
1. **On every change:** `nix flake check` (both hosts evaluate and build): seconds with a warm store. To run on a change by a git hook or a CI job: the owner chooses (below).
2. **The full drill (`lab/restore-drill.sh all`, about 30 minutes on the lab VM):** **before the first deployment, and after any change to the storage, backup, database or Incus modules.** It is the proof that "rebuild from scratch" and "restore" still work.
3. **The same steps on the real machine** from [the runbook](../restore-drill.md), after the installation and before it carries anything the household cannot lose.

The integrated flake is **merged into `reengineering`**, so that the real host is built from the same modules that were proved.

## Open questions: answered

1. **Where do the checks run on their own?** In **GitHub Actions**: `nix flake check` on every pull request and push (`.github/workflows/check.yml`, [ADR 0016](0016-updates-deploys-and-checks.md) and [ADR 0018](0018-deploys-by-the-server.md) section 6). The full drill (an 8 GB VM with four disks, about 30 minutes) is not for a hosted runner: it stays on the owner's workstation.
2. **How often is the full drill repeated?** Before each deployment, after any change to the storage, backup, database or Incus modules, and **once a quarter**, as a reminder that the backups still restore ([the schedule](../schedule.md)).

**Repeated on 2026-10-06, on the tree that is published:** `DRILL RESULT: PASS`, 14 checks, no failed unit (lab times: installation 1034 s, rebuild from the flake 1131 s, restore and checks 372 s; the lab's link is slow).

## Consequences

- `docs/restore-drill.md` is the runbook, written from what the drill did.
- The **exceptions register** keeps entry 1 (pgBackRest's local repository, now in `modules/database.nix`); no new entry was needed: the publication gate, the Incus state bind mount and the disko layout are native NixOS configuration.
- The drill left **new items for the real machine** ([the pending list](../pending.md)): the real disk layout and its first-time provisioning, the real private values, the timings on real data, the offsite restore, the machine learning and the media server with the GPU.
