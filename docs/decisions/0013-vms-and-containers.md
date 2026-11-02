# 0013. The VM and container lab on the server

- **Status:** accepted: Incus with two pools (ZFS on the SSD, a directory pool on the big ext4 disk), Podman instead of Docker, and a declared publication gate
- **Date:** 2026-10-01
- **Phase:** 6, Network and VMs

## Context

The previous setup runs Incus 6.23 next to Docker: two virtual machines (both stopped), one storage pool on LVM, the bridge `incusbr0` next to `docker0`, and a default profile that carries a cloud-init file with the admin's SSH key and a hardening drop-in. That profile lives in Incus's database, not in a repository. The images come from the public `images.linuxcontainers.org` remote. Docker and Incus already coexist on that host, and nobody measured what each does to the other's firewall rules.

How VMs are exposed is settled ([ADR 0010](0010-vm-service-exposure.md): private by default, the VPN for the admin, a declared line for the few public ones). What runs them, and what else it can run, is this phase. The use is tests of every kind, kept ready for any occasion, containers included. The more it can do at equal cleanliness and with zero glue, the better.

## Requirements

- Must: run virtual machines of any operating system (an installer ISO or a cloud image: Linux, a BSD, possibly Windows) on the server's KVM; run containers too; the host side declared in the flake (the manager, its networks, storage pools, profiles, the firewall); a new or temporary instance needs no change to the flake; Docker and the manager on one host without breaking each other's networking or the firewall; instances reachable through the VPN, any protocol; the VM disks on the mid-size disk, not on the system SSD ([ADR 0005](0005-storage-layout-and-filesystem.md)); no script that watches or patches instances.
- Should: snapshots, clones and a quick throwaway cycle; application containers (OCI images) and system containers in the same tool; a web UI that is VPN-only; disk quotas and CPU and memory limits per instance; a declared instance for the few that stay; a small memory use at idle, on a machine that also runs ZFS, PostgreSQL and the services of [ADR 0011](0011-services.md).
- Should not: a hypervisor distribution that replaces the host's operating system (Proxmox); GPU passthrough to a VM in this phase (the GPU belongs to the transcoding containers); a Kubernetes cluster.

## Candidates

| Candidate | What it is | What it can run | Declared on NixOS |
|---|---|---|---|
| A. Incus | VMs, system containers, and (from its recent releases) application containers from OCI images, with snapshots, clones, profiles, a REST API and a web UI | any OS as a VM; any Linux as a container | `virtualisation.incus` with a preseed for networks, pools and profiles; instances are created by commands ([ADR 0010](0010-vm-service-exposure.md)) |
| B. libvirt/QEMU | the classic stack, `virsh` and virt-manager | any OS as a VM; containers only through LXC drivers | `virtualisation.libvirtd`; domains as XML; a community flake (NixVirt) declares them |
| C. microvm.nix | NixOS guests as lightweight VMs, declared as flake outputs | NixOS guests only | the guests are in the flake by construction |
| D. NixOS containers (`systemd-nspawn`) | NixOS guests as containers | NixOS guests only, no other OS, no VM | native |
| E. Podman, or Docker, alone | containers only | OCI images; no VM | `virtualisation.podman` and `virtualisation.oci-containers`; `virtualisation.docker` |

I prefer Podman to Docker, mainly because it is open source. Docker Engine is itself under the Apache 2.0 licence; what differs is that Podman has no daemon and can run without root. The preference is taken as a requirement: the services' containers of [ADR 0011](0011-services.md) must run under Podman, and Docker is measured as the baseline, not as a goal.

The combinations are not exclusive: a container engine is in the plan anyway for Jellyfin and Immich, and Incus can run OCI images itself. The question is which one manager covers the VMs, and whether it can also take the containers for tests so a second tool is not needed.

Criteria, in this order, fixed before any test: range (what it can run from one tool, each tried); P1 and declaration (how much the flake can declare, glue and imperative state); coexistence with Docker (the firewall and the networks of both after a restart, DNS, and the declared firewall staying the gate); the throwaway cycle; memory at idle, disk layout and moving parts.

## Experiments

In the lab VM, with nested virtualization on, so real VMs run inside it (the experiment of [ADR 0010](0010-vm-service-exposure.md) could only use containers).

- R1: Incus with a real VM (a cloud image and an installer ISO), a system container and an OCI application container, with a cloud-init profile declared in the preseed.
- R2: Podman, and Docker as the baseline, each together with Incus on the lab host, with the host firewall of ADR 0010 on.
- R3: libvirt with a declared domain (through NixVirt) and an installer ISO.
- R4: microvm.nix: a NixOS guest declared in the flake.
- R5: for the winner, the throwaway cycle, a declared instance that stays, the web UI behind the VPN address, the storage pool on a separate disk, memory at idle. Repeated on a thin-LVM pool because [ADR 0005](0005-storage-layout-and-filesystem.md) left "ZFS or LVM for Incus's storage" to this phase.
- Read, not run: Windows as a guest (a licence and an image the lab does not have).

## Results

Scripts: `lab/experiments/vms-bakeoff.sh`, `vms-engines-bakeoff.sh`, `vms-others-bakeoff.sh`, `vms-cycle-bakeoff.sh` and `vms-lvm-vm-bakeoff.sh`, in a fresh lab VM (4 cores, 6 GB, a 60 GB system disk and a 30 GB data disk that holds the ZFS pool). The VMs inside it run on nested KVM, so their speeds are lower than on real hardware.

### R1. What Incus runs from one tool

| Check | Result |
|---|---|
| System container (Alpine) | answering `exec` under 1 s after launch, image cached |
| VM from a cloud image (Ubuntu 24.04), 1 GiB, 2 CPUs | the agent answers after 31 to 37 s; the profile's cloud-init created the admin user; the disk is a ZFS volume |
| VM booted from an installer ISO (Alpine, UEFI, secure boot off) | the installer's banner on the serial console after 14 to 15 s: an operating system Incus has no image of boots with one `disk` device and `boot.priority` |
| OCI application container (`docker:nginx:alpine` through `incus remote add docker https://docker.io --protocol=oci`) | has an address after 1 s and answers HTTP 200; launching by digest works; it runs the image's own command with no init system |
| Web UI (`virtualisation.incus.ui.enable`) | answers on the API address |
| Our own configuration | 38 lines (bridge with managed DNS, two pools, the profile with cloud-init, the host firewall for the bridge, forwarding) |

What running it showed:

- Incus's NixOS module declares networks, pools and profiles, but not instances: an instance is created by a command, and its definition lives in Incus's own database under `/var/lib/incus`.
- The image catalogue has two kinds of the same name: copying `ubuntu/24.04/cloud` without `--vm` fetched the container image, and a VM launched from it failed with "Asked for a VM but image is of type container".
- A VM stop issued at once after the first boot hung for 600 s in two of the cycle runs; the same stop took about 1 s when the VM had been running for 30 s. Not diagnosed (nested virtualization, or a guest still starting its shutdown handling); a `--force` stop is the way out.
- Resource limits hold in the kernel, but a container with a 64 MiB memory limit still reports the host's memory through `free`: the view of `/proc` that `lxcfs` gives was not enabled (a declared line, not tested).
- Memory at idle: the host used about 460 to 580 MiB with Incus and the ZFS pool and no instance.

### R2. A container engine next to Incus, with the host firewall as the gate

The host runs nftables with forward filtering on ([ADR 0010](0010-vm-service-exposure.md)). Four variants of the same host: Docker and Podman, each plain (the engine and nothing else) and declared (what the host has to add).

| Check | Docker, plain | Docker, declared | Podman, plain | Podman, declared |
|---|---|---|---|---|
| Container to the Internet | fails | ok | fails | ok |
| Container to an Incus instance | fails | ok | fails | ok |
| Containers resolve each other by name | fails | ok | fails | ok |
| A port published with `-p 8080:80` and no line in the firewall, from outside | 200: public | closed (the gate) | 200: public | closed (the gate) |
| The same, published with an explicit loopback address | not reachable | not reachable | not reachable | not reachable |
| After `systemctl restart nftables` (a rebuild's reload) | keeps working | keeps working | internet still fails | keeps working |
| The engine's own tables | `iptables-nft`: four tables | the same | its own `inet netavark` table | the same |
| Engine daemon memory | 46 MiB | 46 MiB | none (no daemon) | none |

What this shows:

- Both engines are public by accident through the default firewall. With `filterForward` on, the NixOS firewall contains a rule "allow port forward", `ct status dnat accept`: every connection that an engine has address-translated (every `-p` without an address) is accepted, whatever the firewall says. A `docker run -p 8080:80` or `podman run -p 8080:80` is public on the spot. This is [ADR 0010](0010-vm-service-exposure.md)'s "public by accident" reappearing through the engines.
- The closing of it, tested on both: a table of ours, evaluated first, that drops a translated connection unless its original port is on a list (`ct status dnat ct original proto-dst != { 9090 } drop`, 6 lines). The listed port answers, the unlisted `-p 8080:80` does not, and it survives a firewall reload. A reviewed line then says what may be public, for any engine and for Incus's own DNAT. The Docker daemon setting that should make a bare `-p` bind the loopback did not keep the port private (cause not looked into).
- Declared next to each engine: forward rules for the engine's bridges (Docker: `docker0` and `br-*`; Podman: `podman*`) and, for Podman only, port 53 on its bridges (its DNS, `aardvark`, listens on each bridge's address). Everything the engine needs fits in about 10 lines, the same for both.
- Podman needs no daemon and writes its own nftables table; Docker goes through `iptables-nft`. The two coexist with Incus's own table in every variant.
- A service container declared as code under Podman works: `virtualisation.oci-containers` with the Podman backend, an image pinned by digest, a port written as `127.0.0.1:8090:80`. The unit is active, answers on the loopback, is silent from outside, and comes back by itself after `podman kill` (8 s). This is the form [ADR 0011](0011-services.md)'s Jellyfin and Immich containers take, with no Compose file.

### R3. libvirt and R4. microvm.nix

| | libvirt (NixVirt) | microvm.nix |
|---|---|---|
| Declared | yes: the network and the domain are in the flake; at boot the domain is running | yes: `microvm.vms.lab1`, a systemd unit per guest |
| Runs | a VM of any operating system: the Alpine installer ISO booted | NixOS guests only: the guest is a closure built by the flake and its store is the host's, shared read-only through virtiofs |
| Memory | host 840 MiB used with a 1 GiB VM and `libvirtd` | the guest's qemu about 396 MiB of the 512 MiB given |
| Containers, image catalogue, UI | none | none |
| Snapshots | refused on the running ISO domain | a guest is rebuilt, not snapshotted |
| Firewall | its own tables next to ours; two forward lines and a DHCP/DNS rule for `virbr0` are ours | none for user-mode networking |
| Our own configuration | about 58 lines for both in a lab module | |

### R5. The throwaway cycle on Incus, by storage pool (times in ms; VM = the Ubuntu cloud image, 10 GiB disk)

| | ZFS pool | Directory pool | Thin LVM pool |
|---|---|---|---|
| Container: create and answering | 736 | 403 | 1,453 |
| Container: snapshot, restore, clone, delete | 84, 1,087, 725, 943 | 208, 916, 428, 815 | 365, 2,235, 1,257, 1,533 |
| VM: create and agent answering | 34,805 | 36,693 | 33,684 |
| VM: snapshot (stopped) | 112 | 3,485 | 737 |
| VM: restore (stopped) | 313 | 3,590 | 1,240 |
| VM: clone (stopped) | 1,113 | 11,394 | 1,690 |
| Space for the clone | +9.9 MiB (copy-on-write) | +1.2 GB (a full copy) | thin volumes (not measured) |
| What it needed on NixOS | the `zfs` kernel support and a `hostId` | nothing | two kernel modules (`dm_thin_pool`, `dm_snapshot`), declared in `boot.kernelModules` on a real host |

For VMs the pool decides the cost of the lab's habit (snapshot, break, restore): ZFS makes it a third of a second and a clone costs no space; a directory pool copies the whole disk; thin LVM sits in between. Containers are sub-second to two seconds everywhere.

### What the lab did not show

The speed on real hardware (the VMs here are nested); a Windows guest; GPU passthrough or sharing; Incus's own backup and recovery (the instances' definitions are in `/var/lib/incus`, the disks in the pool, and a restore of an instance onto a rebuilt host was not tried); ZFS on a shingled disk, which is known to suffer on random writes; `lxcfs`; rootless Podman; Quadlet; Immich's multi-container set under Podman; Jellyfin's `/dev/dri` in a Podman container (gate G2).

### R6. Two pools

Most VM disks go on the mid-size SMR disk kept as ext4, and the SSD's ZFS pool is for what needs speed (a database VM). The lab stands in the disk with a loop-file ext4, which cannot imitate a shingled disk's speed. All declared in the flake (`vms.nix`):

| Check | Result |
|---|---|
| The preseed creates a directory pool `smr` (a folder on the ext4 disk) and the ZFS pool `zp`, and two profiles: `default` (root on `smr`) and `fast` (root on `zp`) | yes; the directory pool needs its folder to exist and the disk mounted first: `systemd.tmpfiles` and `RequiresMountsFor` on the preseed unit, 2 lines, or the preseed fails with "Source path doesn't exist" |
| A container and a VM launched with no option | both land on `smr` |
| The same with `-p default -p fast` | both land on `zp` |
| The publication gate as a module with an option (`tidepool.publishGate.allowedPorts = [ ... ]`, default none) | declared, no manual step: the table is present at boot with an empty list (every published port dropped), and a port appears on the list only by a reviewed line |

On the `smr` pool a VM's snapshot is a full copy (3.5 s) and a clone 1.2 GB and 11 s; that is fine for test machines, which is the use.

## Reading the results against the criteria

1. Range: Incus alone covers all three kinds of workload in one tool: a VM from a catalogue image, a VM from any installer ISO, a system container, and an application container from an OCI image pinned by digest. libvirt covers VMs of any system only; microvm.nix only NixOS guests; Podman and Docker only application containers.
2. P1 and declaration: the ranking reverses. libvirt through NixVirt and microvm.nix declare their guests in the flake; Incus declares everything around the instances (network, pools, profile with cloud-init, UI, firewall) but not the instances. For tests and throwaway machines that is the intended use; for a machine that stays it is a gap, closed by running the things that stay as services ([ADR 0011](0011-services.md): native modules or declared Podman containers), which is already the plan.
3. Coexistence: both engines work beside Incus with the same 10 declared lines. The real difference is the NixOS firewall's "allow port forward" rule that makes any bare `-p` public, closed by a 6-line table of ours.
4. The throwaway cycle: a ZFS pool makes a VM's snapshot, restore and clone fractions of a second and its clone free of space.
5. Memory and moving parts: Incus idle, a few hundred MiB with the ZFS pool and no instance; Podman, none while no container runs; libvirt, similar to Incus.

## Decision

Incus as the one manager for tests, with its pool on ZFS; Podman for the containers that stay; neither Docker nor libvirt nor microvm.nix.

- Incus (`virtualisation.incus`, the preseed holding the bridge, the pools, the default profile with cloud-init, the UI on the VPN address only): VMs of any system, system containers and OCI application containers, all from it. Docker is not needed for containers for tests: `incus launch docker:<image>` runs them.
- Podman, not Docker, for the service containers of [ADR 0011](0011-services.md) (Jellyfin, Immich): `virtualisation.oci-containers` with the Podman backend, images pinned by digest, ports written with an address, no Compose file. It meets my preference and costs nothing the lab could measure: the same 10 declared lines, no daemon, one table. Docker is dropped, and [the host specification's H04](../specs/host.md) changes to Podman.
- The publication gate (a module of the flake, `publish-gate.nix`, evaluated before the NixOS firewall's own rule): a port is public only if it is on a reviewed list, for Podman, for Incus's declared DNAT and for anything else. It enforces [ADR 0010](0010-vm-service-exposure.md)'s principle against the engines' default and replaces trusting each `-p`.
- Two pools, both declared: `zp`, ZFS on the SSD, for what needs speed (a VM that runs a database: instant snapshot, restore and clone), chosen per instance with the `fast` profile (`incus launch ... -p default -p fast`); and `smr`, a plain directory pool on the mid-size disk, which stays ext4, the default for every other instance. That keeps copy-on-write off a shingled disk. The SSD's share for VMs is a quota to set when the SSDs are bought ([ADR 0005](0005-storage-layout-and-filesystem.md)).
- libvirt with NixVirt is the fallback for a VM of another system that must be declared and permanent; microvm.nix is the fallback for a NixOS service that should be a VM. Neither is adopted now because no use case needs them, and each would be a second manager.

Consequences and what stays open:

- The instances' definitions live in Incus's database (`/var/lib/incus`) and the disks in the pool: both must be in the backup ([ADR 0004](0004-backup.md)), and a restore of an instance onto a rebuilt host is untested; it belongs to the drill of phase 7.
- The mid-size SMR disk is not given a copy-on-write pool. How slow it is for a VM is not measured (the lab's loop file is a plain ext4 on a fast disk); the first real VMs on it will show it, and the `fast` profile is the escape for any instance that suffers.
- A VM stop issued right after its first boot hung for 600 s in the lab (not diagnosed); the first stop of a new VM on real hardware is to be watched.
- `lxcfs` (so that a limited container reports its limit) is a declared line, untested.
- The real checks at deployment: Jellyfin's `/dev/dri` and Immich's machine learning in Podman containers (gate G2), the Immich set (database over its Unix socket through a bind mount), and Podman's behaviour across a reboot.
