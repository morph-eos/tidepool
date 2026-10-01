# 0001. The lab: throwaway QEMU/KVM VMs on the workstation

- **Status:** accepted
- **Date:** 2026-09-29
- **Phase:** 0, Lab

## Context

v0 was never rebuilt from an empty disk: the rebuild order in the README "has not been rehearsed on a blank machine". The new system is built by trying several
solutions per phase (see [the method](../method.md)), which only works if a whole machine can be created, broken and thrown away in seconds, and never on the
server the household uses every day.

## Requirements

- **Must:** a full Ubuntu 24.04 machine (systemd, its own kernel, real disks), not a container; nothing installed with root on the workstation; reproducible from the repo.
- **Should:** fast create/snapshot/restore; the same image as the real server; scriptable, so the CI phase can reuse it.
- **Won't:** GPU passthrough. Hardware transcoding (VA-API) can only be verified on the real server.

## Options considered

| Option | Result in one line |
|---|---|
| QEMU/KVM driven by a small script (`lab/vm.sh`) | works with no privileges; the guest is reached through forwarded localhost ports |
| Incus VMs | the same QEMU/KVM underneath, with nicer snapshots and bridged networking, but it needs root to install and configure, and it is itself a candidate of phase 6 |
| Containers only (LXC, Docker) | cannot test the host layer: kernel parameters, `ssh.socket`, udev, fstab, kdump |

## Criteria

1. Needs no root on the workstation.
2. Keeps the host layer testable (a real VM, a real kernel).
3. Speed of the create/snapshot/restore loop.
4. Does not pre-empt a later decision (Incus in phase 6).

## Results

Measured on the workstation (12 threads, KVM accessible, image `ubuntu-24.04-server-cloudimg-amd64`, checksum verified):

| Operation | Time |
|---|---|
| create (overlay disk + cloud-init seed) | under 1 s once the image is cached |
| first boot to SSH | about 20 s |
| snapshot (VM stopped) | 0.04 s |
| restore (VM stopped) | 0.04 s |
| restore, boot and verify | about 21 s |

The restore was verified with a marker file: present before, gone after. A first check was wrong (it tested a path the guest user could not read), which is why the
check now creates the marker in a world-readable place.

## Later use (added 2026-10-01)

The measurements above are for the Ubuntu 24.04 cloud image, which phase 1 used. After [ADR 0002](0002-host-as-code.md) chose NixOS, the same `lab/vm.sh` runs the NixOS lab VM (`host-n`, installed by `lab/nixos-install.sh`) for every later phase; the create, snapshot and restore times were **not re-measured for NixOS** (the install takes 229 s, [ADR 0002](0002-host-as-code.md)). Two lab habits were added by experience: a snapshot must cover **every disk**, and rebuilds run as `systemd-run` units because a tool call that exceeds ten minutes is moved to the background and can leave the configuration half copied.

## Decision

QEMU/KVM with `lab/vm.sh`. The one sentence that tips it: it works today with zero privileges, and switching to Incus later means replacing one thin script.

## Consequences

- Easier: every experiment starts from a known snapshot and ends with a throwaway VM.
- Harder: user-mode networking gives one VM per port set; two VMs that must talk to each other need a bridge or an Incus network. Revisit if phase 2 (restore between two
  machines) needs it.
- Not covered: GPU transcoding, real disk serial numbers and udev symlinks, the wifi watchdog. These are verified on the server, in a maintenance window.
