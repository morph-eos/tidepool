# Host specification (the same test for every candidate)

Distilled from the host layer of v0 (see [the README](../../README.md)): SSH policy, fail2ban, Docker (now Podman), crash diagnostics, a systemd timer, disks identified by serial number and
a delivered secret. Every candidate for "the host as code" (see [ADR 0002](../decisions/0002-host-as-code.md)) must reach this state from an empty Ubuntu 24.04 machine, with one command,
and [`lab/check-host.sh`](../../lab/check-host.sh) verifies it from the outside. The checker knows nothing about the tool that built the machine.

| ID | Requirement | Why (v0 lesson) |
|---|---|---|
| H01 | An admin user exists with SSH key login and sudo | the only way in is a key |
| H02 | sshd listens on **2222 only**, password login off, `PermitRootLogin prohibit-password`, `MaxAuthTries 3` | non-default port, key only; on Ubuntu 24.04 `ssh.socket` decides the port, not `sshd_config` |
| H03 | fail2ban is active with an `sshd` jail on 2222, `maxretry 3` | ban after three attempts |
| H04 | **Podman** answers and a declared container runs (changed from Docker, [ADR 0013](../decisions/0013-vms-and-containers.md)) | the stack's containers are declared as units; there is no Compose file |
| H05 | The kernel command line has `softlockup_panic=1`, and a crash kernel is **loaded** and reserves exactly 256 MiB | a lockup becomes a panic with a vmcore instead of a hung machine |
| H06 | A `tidepool-fixperms.timer` exists, is enabled and active (it restores the executable bit on scripts) | Samba and macOS strip `+x` |
| H07 | The data disk with serial `TPDATA0001` has an ext4 filesystem, mounted on `/mnt/nas` through a stable identifier in `fstab` (`UUID=` or `/dev/disk/by-...`, never `/dev/sdX`) | disks are identified by serial, never by `/dev/sdX` |
| H08 | Time zone is `Europe/Rome` and the clock is synchronized | logs and cron must agree |
| H09 | `/etc/tidepool/secrets.env` exists, owned by root, mode 0600, and holds `TIDEPOOL_TEST_SECRET` | a secret is delivered without being world-readable (value never printed) |

Not checked by the script, but measured for every candidate:

| Measure | How |
|---|---|
| **Rebuild time** | wall clock from the `baseline` snapshot to all checks green, including the reboot |
| **Manual steps** | number of commands a person types; v0 baseline is the 9 steps of the rebuild order |
| **Idempotency** | run the same command a second time: how many changes does it report? The goal is zero |
| **Survives reboot** | run the checker again after a reboot (H02 and H05 are the ones that fail) |
| **Drift** | change something by hand, run again: is it put back? |
| **Effort** | how long it took to get working, and how many times I had to look something up |

## Revisions

- **2026-09-29, after candidate A (Ansible), before candidate B (NixOS).** Three requirements were written in Ubuntu terms and were made about behavior, so that they are fair to any candidate:
  H04 no longer names the apt repository, H05 checks that the crash kernel is loaded and how much memory it holds instead of whether a package is installed, and H07 accepts any
  stable identifier. The change was made in the open, and Ansible was verified again against the new version. The stricter H05 found a real defect in the first Ansible role:
  the kdump package adds its own `crashkernel=` (512M) after ours and the last one wins. v0's `setup_kdump.sh` stripped the old value first, so the first Ansible role was a regression.
