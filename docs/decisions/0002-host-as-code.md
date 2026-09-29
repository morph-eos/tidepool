# 0002. The host as code

- **Status:** proposed (experiments not run yet)
- **Date:** 2026-09-29
- **Phase:** 1, Foundations

## Context

In v0 the host layer is 34 shell scripts that have to be idempotent by discipline, with no way to test them and no rebuild ever rehearsed. The README's lessons
say the same thing three times: a change that lives only in a shell history, a manual edit nobody can detect, `/etc` that no backup covers.
The new host must be reproducible from an empty machine with one command, and tell me when it has drifted.

## Requirements

- **Must:** reach the state of [the host specification](../specs/host.md) (H01-H09) from an empty Ubuntu 24.04 machine; idempotent (a second run changes nothing);
  run from the workstation, not on the server; keep working with a desktop session (the server is also a media center); no secret in clear text in the repository.
- **Should:** show drift; be understandable by someone reading the repo for the first time; a rebuild measured in minutes.
- **Won't:** Kubernetes, and any hypervisor with exclusive GPU passthrough (the machine is used daily as a media center).

## Options considered

| Option | Branch / tag | Time box | Result in one line |
|---|---|---|---|
| A. Ansible (roles, run from the workstation over SSH) | `exp/host-ansible` | one evening | |
| B. NixOS (declarative system, flake) | `exp/host-nixos` | one evening | |

"Keep the v0 shell scripts" is not a candidate: v0 is the baseline the numbers are compared with, not a contender.

## Criteria

Decided before testing, in this order of importance (from the owner: the priorities are a fast, repeatable rebuild and reliability/security; teaching value comes
after, and only for things that are best practice):

1. **Rebuild speed and repeatability:** time from the `empty` snapshot to all checks green, manual steps, idempotency (changes reported by a second run), survives a reboot.
2. **Security and reliability:** secrets handling, how a bad change is rolled back, how many ways there are to lock myself out of the server.
3. **Best practice and teachability:** is this what people who run this seriously actually do, and can a newcomer follow it.
4. **Effort and moving parts:** how long it took to get working within the time box, and how many tools have to be learned and kept up to date.
5. **Fit with the machine:** desktop session, GPU drivers, udev rules and disks by serial keep working.

## Results

### A. Ansible (`exp/host-ansible`, tag `exp-host-ansible`)

Measured in the lab, from the `empty` snapshot of a 4-core, 6 GB VM with a second disk (Ansible 2.21, run from the workstation):

| Measure | Result |
|---|---|
| Checks green ([host spec](../specs/host.md)) | **23 of 23** |
| Rebuild time, empty to all green | **214 s** (includes the kdump reboot; the VM itself boots in about 22 s) |
| Manual steps | **2** (export the test secret, run `ansible-playbook`), after a one-off install of Ansible (53 s, no root) |
| Idempotency | second run: **0 changes**, 39 s |
| Survives a reboot | 23 of 23 |
| Drift | 4 manual changes (sshd option, fail2ban stopped, timer disabled, file mode) all put back in 28 s |
| Effort | working in about 18 minutes of wall clock, with four problems found and fixed on the way (below) |
| Moving parts | Ansible on the workstation, 8 roles, nothing installed on the server |

What went wrong on the way, and would have gone wrong in production:

1. **Not re-runnable at first.** After the first run sshd only listens on 2222, so a playbook that always connects to 22 could never run twice. Fixed by probing which port answers.
2. **The probe lied.** A plain TCP connect succeeds through QEMU's port forwarder even when nothing listens in the guest. The probe now waits for a real `SSH-2.0` greeting.
3. **Role order.** A directory created under `/mnt/nas` before the data disk was mounted is hidden by the mount and gets created again on the next run. The disk is now mounted first.
4. **The checker itself was wrong twice** (`sshd -T` prints `without-password` for `prohibit-password`; the first NTP sync takes seconds). Test tools get tested too.

Safety design: the SSH port changes in three steps (listen on both ports, prove 2222 works from the controller, then drop 22) so a mistake cannot lock the server out.

### B. NixOS (`exp/host-nixos`)

_Not run yet._

## Decision

_Pending._

## Consequences

_Pending._
