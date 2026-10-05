# Encrypted disks, the TPM and signed boot images: installing, and living with them

The design is in [ADR 0005](decisions/0005-storage-layout-and-filesystem.md) (decided 2026-10-05: the TPM alone, **no PIN**, so that the machine reboots by itself; the residual risk is accepted) and was tried in a VM with an emulated TPM and Secure Boot firmware (`lab/tpm-u21.sh`). **It has not been done on the real machine**: the first time, do it at the console.

## What is protected, and what is not

| Situation | Result |
|---|---|
| A disk taken out, sold, returned, thrown away | **closed**: the key is sealed in this machine's TPM |
| The disks moved into another machine (another TPM) | **closed** (measured: the console asks for the passphrase) |
| Another system started on the machine (a USB stick) | **closed** (measured: PCR 7 changes, the TPM answers "policy does not match") |
| The machine switched on by a casual thief | boots by itself; **no local login exists** (the admin has only an ssh key, ssh is open on the VPN only); only the services' own passwords |
| The whole machine in the hands of a skilled, targeted thief | **not covered** (a published attack swaps the disk for a fake one and asks the TPM from its own init; the cure is a PIN, which was declined) |

## Before you start

- Firmware: **UEFI**, Secure Boot **supported**, the **TPM enabled** (find out whether it is a discrete chip or part of the CPU: the discrete ones can be probed on their bus). **Set a firmware password** (it keeps the thief out of the settings).
- **Keep the recovery passphrase** (the one typed at the installation) in Proton Pass **and on paper**. It is the only way in when the TPM refuses.
- A video card's option ROM is signed by Microsoft: the keys are enrolled **with the Microsoft ones** (the default of the module), or the card may not initialise.

## Stage 1: install with LUKS

Put the passphrase in `tidepool.encryption.passphraseFile` (`/tmp/disk-passphrase`) **in the installer's memory** (not on the machine), then install as usual (`nixos-install --flake`; disko formats). The 2 TB disk, formatted by hand once, is made LUKS as well: `cryptsetup luksFormat <disk>`, open it, `mkfs.ext4`, close. The first boot asks for the passphrase on the console.

## Stage 2: signed boot images

1. `sudo sbctl create-keys` (it is in the system already): the keys are in `/var/lib/sbctl` on the encrypted root and **in the Borg job of everything**.
2. Set `tidepool.encryption.secureBoot = true` and rebuild: lanzaboote signs the boot images (**without the keys the first switch stops**, as it did in the lab).
3. Put the firmware in **setup mode** (the "reset to setup mode" or "erase the platform key" entry; **not** "clear all keys": it would empty the revocation list) and reboot twice: systemd-boot enrolls the keys by itself. `bootctl status` then says **Secure Boot: enabled (user)**.

## Stage 3: the TPM

For each LUKS volume (the system partition, the SSD's, the 2 TB disk), with the passphrase in a temporary file:

```
systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 --unlock-key-file=/root/pp <device>
```

`--tpm2-pcrs=7` and nothing else: **PCR 7 is the Secure Boot policy and the key that signs the image, which a kernel update does not change** (measured: the same value before and after a kernel change, and the disks opened by themselves). Do **not** add PCRs of the kernel or the boot loader files (every update would then ask for the passphrase), and **no PIN**. Reboot: there must be no prompt.

## Living with it

- **A kernel update** (the deploy of [ADR 0018](decisions/0018-deploys-by-the-server.md)): the machine reboots by itself and the disks open. **Rehearse the first one at the console.**
- **If the passphrase is asked** (a firmware update changed PCR 7, the firmware lost its keys, the CMOS battery died): type the recovery passphrase, then re-seal: `systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 <device>`. If the firmware came back with **factory keys** instead of setup mode, the machine does not boot the signed images until it is put back into setup mode (stage 2, step 3).
- **If the machine does not come back**, the heartbeat stops and Healthchecks.io mails within minutes ([ADR 0012](decisions/0012-observability.md)).
- **Back up the LUKS headers** of the three volumes (`cryptsetup luksHeaderBackup`) next to the recovery passphrase; the header holds only keys the passphrase protects.
- **A rebuild from blank** (the restore drill) repeats the three stages; the data comes back from the backups.
