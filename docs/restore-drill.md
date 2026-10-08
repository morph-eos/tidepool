# Rebuild and restore: the runbook

Written from what `lab/restore-drill.sh` did in the lab ([ADR 0014](decisions/0014-automation-and-restore-drill.md)), so that the same steps can be done by hand on the real machine. Times are the lab's (small data, nested virtualization): the real ones will be longer.

## What survives and what is lost

| Lost | Comes back from |
|---|---|
| The system disk and the SSD (the ZFS pool: every service's files, the databases) | **the flake** (the system), **Borg** on the 16 TB disk (the files), **pgBackRest** on the 16 TB disk (the databases) |
| The 16 TB disk | the data on the SSD is intact; **run a backup at once** to rebuild the repositories; the media is a plain copy that must be restored from where it was copied |
| The 2 TB disk | the offsite repository is rebuilt by the next Borg run; **the Incus instances on it are lost** (tests, replaceable) |
| Everything | the offsite copy ([ADR 0007](decisions/0007-offsite-copy.md)): `proton-offsite-cli auth login`, then `proton-offsite-cli filesystem download /my-files/tidepool/borg-offsite <dir>`, then `BORG_RELOCATED_REPO_ACCESS_IS_OK=yes borg check --verify-data <dir>` with the passphrase from its custody (Proton Pass and paper); rehearsed byte for byte in the lab (`lab/proton-offsite/`), **not on the real data** |

**You need:** the repository, the **age key** (custody: [ADR 0003](decisions/0003-secrets.md)), the Borg passphrase (it is a secret in the same sops file, so it comes with the age key), and a NixOS installer USB.

## A. First-time provisioning of the two large disks (once, outside the flake)

The flake **never formats** the 16 TB and the 2 TB disk, so that a reinstall cannot wipe a backup. When a disk is first put into service:

```
mkfs.ext4 <the disk by its stable path>
mount it, then:  mkdir incus-state          # on the 2 TB disk only: Incus's state lives there (modules/vms.nix)
```

## B. Rebuild from scratch

1. Boot the installer. Copy the repository's `nixos/` and the age key to it.
2. Make the layout from the flake (this wipes **only** the system disk and the SSD, which `modules/storage.nix` names):
   `nix run github:nix-community/disko -- --mode destroy,format,mount --yes-wipe-all-disks --flake path:nixos#<host>`
3. Put the age key where sops-nix looks: `install -m 600 age.key /mnt/var/lib/sops-nix/key.txt`.
4. `nixos-install --flake path:nixos#<host> --no-root-passwd`, then reboot.

Lab: **547-559 s** from the disaster to a booted system. The services start **empty**; `incus-preseed` and the others are active, `PostgresArchiveFailing` fires until step C ends with a backup (expected).

## B2. Rebuild with the encrypted layout (tried in the lab on 2026-10-05: `DRILL_SECURE=1`)

The same drill with LUKS, the TPM and signed boot images ([the encryption runbook](encryption-runbook.md)). What differs from B, and what the lab measured:

1. **The Secure Boot signing keys come back first.** The firmware still holds the **old** keys; boot images signed with new ones would not start. `/var/lib/sbctl` is in the Borg job of everything, so **before `nixos-install`** take it from the newest archive of the repository on the surviving 16 TB disk, mounted **read-only** (`borg extract --bypass-lock ::<archive> var/lib/sbctl`, from `/mnt`). The installer's RAM holds the store: **give it about 10 GB** (with 6 GB the installer ran out of memory when it also downloaded Borg).
2. Make the layout (disko asks for the passphrase through `tidepool.encryption.passphraseFile`, a file in the installer's memory), install the host **with `secureBoot` on** (`lab-secure-sb`). The 2 TB disk is **not** formatted: its LUKS volume and its TPM seal survive.
3. **First boot:** the firmware is in setup mode (on a real machine Secure Boot was switched off for the installer, whose image is not signed with your keys); the new root and pool ask for the **recovery passphrase** (typed once, it opens all three). Secure Boot is still off.
4. **Second boot (reboot once more):** the firmware enrolls the restored keys by itself: **Secure Boot enabled (user)**, and **PCR 7 is the same value as before the disaster** (`ab98654a...`), so the 2 TB disk's old seal is valid.
5. **Seal the two new volumes to the TPM** (`systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 ...`, as in stage 3 of the runbook) and reboot: **no passphrase is asked**; all three volumes open by themselves.
6. **Restore as in C.**

Lab: the installation **879 s** (the downloads retried now and then), the restore and the checks **299 s**, **`DRILL RESULT: PASS`, 14 checks, 0 failed units**. **If the signing keys were lost** (no archive had them), the machine would have to be put in setup mode with **new** keys; PCR 7 would change and **every** volume, the 2 TB disk included, would need the recovery passphrase and a new seal: the keys are the reason the backup holds `/var/lib/sbctl`. Not tried on a real machine.

## C. Restore

Decide the moment **T** (the last good one). The files come from the **first Borg archive at or after T**; the database goes **to T**.

1. **Stop the services and the timers:** the Borg and pgBackRest timers, nginx, Nextcloud's php-fpm, Vaultwarden, the Immich containers, Syncthing, Prometheus, Alertmanager.
2. **Files:** empty `/srv/data` and `/var/lib/vaultwarden`, then from `/`:
   `BORG_PASSCOMMAND="cat /run/secrets/borg-passphrase" BORG_REPO=/mnt/backup16/borg-everything borg extract ::<archive>`
   (list the archives with `borg list --short`; their names carry the local start time and sort).
3. **Database:** stop PostgreSQL, empty `/var/lib/postgresql/17`, then as `postgres`:
   `pgbackrest --stanza=default --type=time --target="<T as YYYY-MM-DD HH:MM:SS+00>" --target-action=promote restore`
   and start PostgreSQL. (Lab: 20 s for a 190 MB repository.)
4. **Incus:** nothing to do for instances on the 2 TB disk: the host finds them as they were. Instances on the SSD's `fast` pool are lost.
5. **Start** PostgreSQL, nginx, Nextcloud's php-fpm, Vaultwarden, the Immich containers, Syncthing, Prometheus, Alertmanager and the timers.
6. **End with a backup:** `systemctl start pgbackrest-default-weekly borgbackup-job-everything borgbackup-job-offsite`. It makes the repositories current and clears `PostgresArchiveFailing`.

Lab: **167-169 s** from the first command to the end of the checks.

**Run the drill on a fresh repository.** A restore promotes a new timeline, and the machine then archives its WAL of that timeline into the **same** pgBackRest repository. A second restore to the same target (a drill resumed after an interrupted one, on the same disks) follows the newest timeline and stops with `recovery ended before configured recovery target was reached` (found on 2026-10-08, when a drill was interrupted and resumed). The drill makes its own VM and disks, so a normal run is clean; to restore a second time from a repository that has been restored once, add `--target-timeline=current` to the command above.

## D. Check it (what the drill checks)

Immich: the number of assets is the number at T, and every original is served. A marker row written before T is in each database, one written after is not. Nextcloud and WebDAV: the files at T, content included, **including what was deleted after T**. Vaultwarden answers and its RSA key (outside the database) is the one that was backed up. An Incus instance on the 2 TB pool is back with its file. `borg check --verify-data` passes on both repositories; `pgbackrest check` passes; no unit has failed.

## E. Run the drill in the lab

```
lab/vm.sh create host-t --blank --cpus 4 --mem 8192 --disk 40 --data-disk 20 --extra-disk 30 --extra-disk 15
TIDEPOOL_HOST=lab TIDEPOOL_LAYOUT=disko lab/nixos-install.sh host-t     # the first install, about 9 minutes
lab/restore-drill.sh all                                                 # seed, disaster, rebuild, restore, verify: about 30 minutes
```

It ends in `DRILL RESULT: PASS` or `FAIL`, with the times in `/tmp/drill`. The encrypted variant: `lab/vm.sh create host-s --uefi --tpm --blank --disk 30 --data-disk 10 --extra-disk 6 --extra-disk 6 --mem 10240`, the steps of `lab/experiments/tpm-u21.sh`, then `DRILL_VM=host-s DRILL_SECURE=1 DRILL_DISK_GB=30 DRILL_DATA_GB=10 lab/restore-drill.sh seed`, `disaster`, `restore`.

## E2. Between drills: the checks that run by themselves

On the real machine two things run on a timer and need no one ([ADR 0015](decisions/0015-backup-verification.md)): **borgmatic's checks** (weekly, and every three months a full data verification) and **a monthly restore of the latest database backup into a scratch folder**. They are what stand between two drills.

## F. On the real machine, what this does not tell you yet

The timings on 165 GB, the offsite restore, the real disk layout (UEFI, LUKS with the TPM, lanzaboote), the real certificates, mail and heartbeat, the GPU containers. They are in [the pending list](pending.md).
