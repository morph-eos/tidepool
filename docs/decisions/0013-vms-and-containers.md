# 0013. The VM and container lab on the server

- **Status:** proposed (2026-10-01): framing and criteria, **no experiment run yet**
- **Date:** 2026-10-01
- **Phase:** 6, Network and VMs

## Context

v0 runs **Incus 6.23** next to Docker. Read on the server (2026-10-01, read-only): **two virtual machines, both stopped** (`test-proxy` from June, `Loki2` from September), one storage pool on **LVM** (`vmquota`), the bridge `incusbr0` next to `docker0`, and a **default profile that carries a cloud-init file with the admin's SSH key and a hardening drop-in**: that profile lives in Incus's database, not in a repository. The images come from the public `images.linuxcontainers.org` remote. Docker and Incus already coexist on the v0 host; nobody measured what each does to the other's firewall rules.

How the VMs are **exposed** is settled ([ADR 0010](0010-vm-service-exposure.md): private by default, the VPN for the owner, a declared line for the few public ones). **What runs them, and what else it can run, is this phase.**

The owner's use: **tests of every kind, kept ready for any occasion**, "even containers if possible"; **the more it can do, at equal cleanliness and with zero glue, the better**.

## Requirements

- **Must:** run **virtual machines of any operating system** (an installer ISO or a cloud image: Linux, a BSD, possibly Windows) on the server's KVM; run **containers** too; **the host side declared in the flake** (the manager, its networks, storage pools, profiles, the firewall); a **new or temporary instance needs no change to the flake** ([ADR 0010](0010-vm-service-exposure.md)); **Docker and the manager on one host without breaking each other's networking or the firewall**; instances reachable by the owner through the VPN, any protocol; the VM disks on the **2 TB disk**, not on the system SSD ([ADR 0005](0005-storage-layout-and-filesystem.md)); no script that watches or patches instances.
- **Should:** **snapshots, clones and a quick throwaway cycle** (the lab's own habit); **application containers (OCI images) and system containers in the same tool**, not two; a **web UI** that is VPN-only (the owner uses Incus's today); disk quotas and CPU and memory limits per instance; a **declared instance** for the few that stay (a service VM), without hand commands; memory use at idle small, on this machine that also runs ZFS, PostgreSQL and the services of [ADR 0011](0011-services.md).
- **Won't:** a hypervisor distribution that replaces the host's operating system (Proxmox); GPU passthrough to a VM in this phase (the GPU belongs to the transcoding containers); a Kubernetes cluster.

## Candidates

| Candidate | What it is | What it can run | Declared on NixOS |
|---|---|---|---|
| **A. Incus** (the v0 manager) | VMs, system containers, and (from its recent releases) **application containers from OCI images**, with snapshots, clones, profiles, a REST API and a web UI | any OS as a VM; any Linux as a container | `virtualisation.incus` with a **preseed** for networks, pools and profiles; **instances are created by commands** ([ADR 0010](0010-vm-service-exposure.md) found this) |
| **B. libvirt/QEMU** | the classic stack, `virsh` and virt-manager | any OS as a VM; containers only through LXC drivers, not the focus | `virtualisation.libvirtd`; domains as XML; a community flake (NixVirt) declares them |
| **C. microvm.nix** | **NixOS** guests as lightweight VMs, declared as flake outputs | **NixOS guests only** | the guests are in the flake by construction |
| **D. NixOS containers** (`systemd-nspawn`) | NixOS guests as containers, declared in the host configuration | NixOS guests only, no other OS, no VM | native |
| **E. Docker alone** | containers only | OCI images; **no VM** | `virtualisation.docker` (already in the plan for the services) |

**Combinations, not exclusive:** E is in the plan anyway for Jellyfin and Immich ([ADR 0011](0011-services.md)). The question is which **one** manager (A, B or C-plus-something) covers the VMs, and whether it can also take the owner's "containers for tests" so a second tool is not needed.

## Criteria, in this order (to be confirmed by the owner before any test)

1. **Range (measured):** what it can run from one tool: a VM of another operating system, a system container, an OCI application container; each tried.
2. **P1 and declaration:** how much of it the flake can declare, lines of our own, **glue and imperative state** (the Incus profile of v0 is the example to avoid).
3. **Coexistence with Docker** (measured): the firewall and the networks of both after a restart of each, DNS, a container reaching a VM and the other way round, and **the declared firewall staying the gate** ([ADR 0010](0010-vm-service-exposure.md)).
4. **The throwaway cycle:** create, snapshot, restore, clone, destroy: times and the commands it takes.
5. **Memory at idle, disk layout (the 2 TB), and the moving parts.**

## Experiments planned (in the lab VM, on `exp/vms-<candidate>`)

The workstation's CPU is AMD with **nested virtualization on** (checked), so real VMs can run inside the NixOS lab VM, which the experiment of [ADR 0010](0010-vm-service-exposure.md) could not do (it used containers).

- **R1.** Incus with a **real VM** (a cloud image and an installer ISO), a system container and an **OCI application container** (for example the image of a small web server), the owner's cloud-init as a profile declared in the preseed.
- **R2.** **Docker and Incus together** on the lab host: both enabled, restart each, check the firewall rules, DNS and the paths between a Docker container, an Incus container and a VM, with the host firewall of ADR 0010 on.
- **R3.** **libvirt** with a declared domain (through NixVirt) and an installer ISO, against the same checks.
- **R4.** **microvm.nix**: a NixOS guest declared in the flake, boot time, memory, what it cannot run.
- **R5.** For the winner: the **throwaway cycle**, a declared instance that stays (a service VM), the web UI behind the VPN address, the storage pool on a separate disk, memory at idle.
- **Read, not run:** the `v0` instances' real use and sizes are read-only facts above; Windows as a guest (a licence and an image the lab does not have).

## Not yet decided

Everything above is a plan: no number in this ADR comes from this phase's experiments yet.
