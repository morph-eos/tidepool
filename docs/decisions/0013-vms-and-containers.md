# 0013. The VM and container lab on the server

- **Status:** accepted (2026-10-02): Incus with two pools (ZFS on the SSD, a directory pool on the big ext4 disk), Podman instead of Docker, and a declared publication gate; the owner confirmed it in words on 2026-10-02
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
| **E. Podman, or Docker, alone** | containers only | OCI images; **no VM** | `virtualisation.podman` and `virtualisation.oci-containers` (Podman backend); `virtualisation.docker` |

**The owner prefers Podman to Docker, mainly because it is open source** (2026-10-01). Docker Engine is itself under the Apache 2.0 licence; what differs is that Podman has no daemon and can run without root, and the Docker **Desktop** product is not open source (not relevant on a server). The preference is taken as a requirement: **the services' containers of [ADR 0011](0011-services.md) must run under Podman, and Docker is measured as the baseline**, not as a goal.

**Combinations, not exclusive:** a container engine is in the plan anyway for Jellyfin and Immich ([ADR 0011](0011-services.md)), and Incus can run OCI images itself. The question is which **one** manager (A, B or C-plus-something) covers the VMs, and whether it can also take the owner's "containers for tests" so a second tool is not needed.

## Criteria, in this order (confirmed by the owner on 2026-10-01, before any test)

1. **Range (measured):** what it can run from one tool: a VM of another operating system, a system container, an OCI application container; each tried.
2. **P1 and declaration:** how much of it the flake can declare, lines of our own, **glue and imperative state** (the Incus profile of v0 is the example to avoid).
3. **Coexistence with Docker** (measured): the firewall and the networks of both after a restart of each, DNS, a container reaching a VM and the other way round, and **the declared firewall staying the gate** ([ADR 0010](0010-vm-service-exposure.md)).
4. **The throwaway cycle:** create, snapshot, restore, clone, destroy: times and the commands it takes.
5. **Memory at idle, disk layout (the 2 TB), and the moving parts.**

## Experiments (in the lab VM, branch `exp/vms-incus`; all five were run)

The workstation's CPU is AMD with **nested virtualization on** (checked), so real VMs can run inside the NixOS lab VM, which the experiment of [ADR 0010](0010-vm-service-exposure.md) could not do (it used containers).

- **R1.** Incus with a **real VM** (a cloud image and an installer ISO), a system container and an **OCI application container** (for example the image of a small web server), the owner's cloud-init as a profile declared in the preseed.
- **R2.** **Podman, and Docker as the baseline, each together with Incus** on the lab host: both enabled, restart each, check the firewall rules, DNS and the paths between a Docker container, an Incus container and a VM, with the host firewall of ADR 0010 on.
- **R3.** **libvirt** with a declared domain (through NixVirt) and an installer ISO, against the same checks.
- **R4.** **microvm.nix**: a NixOS guest declared in the flake, boot time, memory, what it cannot run.
- **R5.** For the winner: the **throwaway cycle**, a declared instance that stays (a service VM), the web UI behind the VPN address, the storage pool on a separate disk, memory at idle.
- **Read, not run:** Windows as a guest (a licence and an image the lab does not have).
- **Added while running:** R5 was repeated on a **thin-LVM pool** because [ADR 0005](0005-storage-layout-and-filesystem.md) left "ZFS or LVM for Incus's storage" to this phase.

## Results

`lab/vms-bakeoff.sh`, `lab/vms-engines-bakeoff.sh` (driven by `lab/vms-engines-run.sh`), `lab/vms-others-bakeoff.sh` and `lab/vms-cycle-bakeoff.sh` (and `lab/vms-lvm-vm-bakeoff.sh` for the LVM VM column), in a fresh NixOS lab VM `host-v` (4 cores, 6 GB, a 60 GB system disk and a 30 GB data disk that holds the ZFS pool; branch `exp/vms-incus`, tag `exp-vms-incus`). **The VMs inside it run on nested KVM** (the workstation's CPU has it on), so their speeds are lower than on the real machine. Image downloads ran at about 2 MB/s in the lab and are timed apart.

### R1. What Incus runs from one tool

| Check | Result |
|---|---|
| System container (Alpine) | answering `exec` **under 1 s** after launch, image cached |
| **VM from a cloud image** (Ubuntu 24.04), 1 GiB, 2 CPUs | the agent answers after **31-37 s**; **the profile's cloud-init created the admin user** (`vm-admin`, the owner's key, declared in the preseed); the disk is a ZFS volume; the guest sees 828 MiB |
| **VM booted from an installer ISO** (Alpine, UEFI, secure boot off) | the installer's banner on the serial console after **14-15 s**: an operating system Incus has **no image of** boots with one `disk` device and `boot.priority` |
| **OCI application container** (`docker:nginx:alpine` from Docker Hub, through `incus remote add docker https://docker.io --protocol=oci`) | has an address after **1 s**, answers HTTP 200; **launching by digest works** (`docker:nginx@sha256:...`); it runs the image's own command with no init system |
| Web UI (`virtualisation.incus.ui.enable`) | answers on the API address (HTTP 200) |
| Our own configuration | **38 lines** (bridge with managed DNS, two pools, the profile with cloud-init, the host firewall for the bridge, forwarding) |

What running it showed:
- **Incus's NixOS module declares networks, pools and profiles, but not instances** (its options are `agent`, `bucketSupport`, `preseed`, `socketActivation`, `ui`, `useACMEHost` and a few more): **an instance is created by a command**, and its definition lives in Incus's own database under `/var/lib/incus`.
- **The image catalogue has two kinds of the same name**: copying `ubuntu/24.04/cloud` without `--vm` fetched the container image, and a VM launched from it failed with "Asked for a VM but image is of type container".
- **A VM stop issued at once after the first boot hung for 600 s** in two of the cycle runs (ZFS and directory pools); the same stop took **about 1 s** when the VM had been running for 30 s, and again in the thin-LVM run. **Not diagnosed** (nested virtualization, or a guest still starting its shutdown handling); a `--force` stop is the way out, and the real machine may not show it.
- **Resource limits** hold in the kernel, but **a container with a 64 MiB memory limit still reports the host's 5.9 GB** through `free`: the view of `/proc` that `lxcfs` gives was not enabled (a declared line, **not tested**). A 50 MiB disk quota on a ZFS container shows as 57 MiB.
- Memory at idle: the host used **about 460-580 MiB** with Incus and the ZFS pool and no instance; the Incus service group (including its page cache) 356 MiB.

### R2. A container engine next to Incus, with the host firewall as the gate

The host runs nftables with **forward filtering on** ([ADR 0010](0010-vm-service-exposure.md)). "outside" is a network namespace joined by a virtual cable. Four variants of the same host: Docker and Podman, each **plain** (the engine and nothing else) and **declared** (what the host has to add).

| Check | Docker, plain | Docker, declared | Podman, plain | Podman, declared |
|---|---|---|---|---|
| Container to the Internet | **fails** | ok | **fails** | ok |
| Container to an Incus instance | **fails** | ok | **fails** | ok |
| Incus instance to a container | fails | fails (**isolated by default**) | ok | ok |
| Containers resolve each other by name | **fails** | ok | **fails** | ok |
| **A port published with `-p 8080:80` and no line in the firewall, from outside** | **200: public** | 000 (gate) | **200: public** | 000 (gate) |
| The same, published with an explicit loopback address (`-p 127.0.0.1:8081:80`) | not reachable | not reachable | not reachable | not reachable |
| After `systemctl restart nftables` (a rebuild's reload) | engine keeps working | keeps working | **internet still fails** | keeps working |
| After restarting the engine, and after restarting Incus | Incus ok | all ok | Incus ok | all ok |
| The engine's own tables | `iptables-nft`: `ip nat`, `ip filter`, `ip6 nat`, `ip6 filter` | the same | its own `inet netavark` table | the same |
| Engine daemon memory | 46 MiB | 46 MiB | **none (no daemon)** | none |

What this shows:
- **Both engines are public by accident through the default firewall.** With `filterForward` on, the NixOS firewall contains a rule **"allow port forward": `ct status dnat accept`**: every connection that an engine has address-translated (every `-p` without an address) is accepted, **whatever the firewall says**. A `docker run -p 8080:80` or `podman run -p 8080:80` is public on the spot. This is [ADR 0010](0010-vm-service-exposure.md)'s "public by accident" from v0 reappearing through the engines.
- **The closing of it, tested on both: a table of ours, evaluated first, that drops a translated connection unless its original port is on a list** (`ct status dnat ct original proto-dst != { 9090 } drop`, **6 lines**): the listed port answers, the unlisted `-p 8080:80` does not, **and it survives a firewall reload**. A reviewed line then says what may be public, for any engine and for Incus's own DNAT. **The Docker daemon setting that should make a bare `-p` bind the loopback (`ip = "127.0.0.1"`) did not keep the port private** (200 from outside), cause not looked into.
- **Declared next to each engine:** forward rules for the engine's bridges (**Docker: `docker0` and `br-*`; Podman: `podman*`**, 2 lines per name) and, **for Podman only, port 53 on its bridges** (its DNS, `aardvark`, listens on each bridge's address, so the host firewall's input chain blocks names without it; **Docker's resolver lives inside the container, so it needs no such line**). Everything the engine needs fits in **about 10 lines**, the same for both.
- **Podman needs no daemon and writes its own nftables table; Docker goes through `iptables-nft`** (four more tables, flagged "do not touch" by the tool that made them). The two tools coexist with Incus's own table (`inet incus`) in every variant.
- **A service container declared as code under Podman works:** `virtualisation.oci-containers` with the Podman backend, an image **pinned by digest**, a port written as `127.0.0.1:8090:80`: the systemd unit is active, answers on the loopback, **is silent from outside**, **comes back by itself after `podman kill`** (8 s), and the image reference in use is the digest. This is the form [ADR 0011](0011-services.md)'s Jellyfin and Immich containers take, with **no Compose file**.

### R3. libvirt and R4. microvm.nix

| | libvirt (domain and network declared through NixVirt) | microvm.nix (NixOS guest declared in the flake) |
|---|---|---|
| Declared | **yes**: the network and the domain are in the flake; at boot the domain is **running** | **yes**: `microvm.vms.lab1`, a systemd unit per guest |
| Runs | a VM of **any operating system**: the Alpine installer ISO booted ("Welcome to Alpine Linux 3.22" in the serial log) | **NixOS guests only**: the guest is a closure built by the flake and its store is the host's, shared read-only through virtiofs |
| Answers | the declared domain **running**, the bridge `virbr0` with NAT and DHCP | the guest's nginx answers HTTP 200 through a forwarded port (about 40 s after boot); the guest needed **networkd and DHCP declared** before it did (a first try returned connection reset) |
| Memory | host 840 MiB used with a 1 GiB VM and `libvirtd`; **libvirtd 610 MiB** (page cache included) | the guest's qemu **about 396 MiB** of the 512 MiB given |
| Containers, image catalogue, UI | **none**: no catalogue of images (a cloud image needs the file and a seed ISO by hand, not tried); a LXC connection answers but has no image source, **not tried**; no web UI in the base | **none** |
| Snapshots | **refused** on the running ISO domain (needs qcow2 disks, `virsh` commands) | a guest is rebuilt, not snapshotted |
| Firewall | its own `ip libvirt_network` and `ip6` tables next to ours; **two forward lines and a DHCP/DNS rule for `virbr0`** are ours | none for user-mode networking |
| Our own configuration | **about 58 lines for both** in `others.nix` (the domain XML is hand-written there) | |

### R5. The throwaway cycle on Incus, by storage pool (times in ms; VM = the Ubuntu cloud image, 10 GiB disk)

| | ZFS pool | Directory pool | Thin LVM pool |
|---|---|---|---|
| Container: create and answering | 736 | 403 | 1,453 |
| Container: snapshot, restore, clone, delete | 84, 1,087, 725, 943 | 208, 916, 428, 815 | 365, 2,235, 1,257, 1,533 |
| VM: create and agent answering | 34,805 | 36,693 | 33,684 |
| **VM: snapshot (stopped)** | **112** | 3,485 | 737 |
| **VM: restore (stopped)**, marker back | **313** | 3,590 | 1,240 (marker back) |
| VM: restore, boot, answering | 14,370 | 14,749 | 16,162 |
| **VM: clone (stopped)** | **1,113** | 11,394 | 1,690 |
| **Space for the clone** | **+9.9 MiB** (copy-on-write) | **+1.2 GB** (a full copy) | thin volumes (the space of the clone was **not** measured) |
| What it needed on NixOS | the `zfs` kernel support and a `hostId` | nothing | **two kernel modules loaded by hand** (`dm_thin_pool`, `dm_snapshot`; a pool creation and a launch failed with "Required device-mapper target(s) not detected" until then): in a real host they are declared (`boot.kernelModules`) |

The thin-LVM VM column comes from a **separate run** (a first pass of the script lost its restore to a stuck stop, and the second run stopped the VM with `--force` for the restore; the graceful stop of a settled VM took 6 s there). Containers are sub-second to two seconds everywhere. **For VMs the pool decides the cost of the lab's habit** (snapshot, break, restore): ZFS makes it a third of a second and a clone costs no space; a directory pool copies the whole disk; thin LVM sits in between.

### What the lab did not show

The **real machine's speed** (the VMs here are nested); a **Windows** guest (no image or licence); **GPU** passthrough or sharing; **Incus's own backup and recovery** (the instances' definitions are in `/var/lib/incus`, the disks in the pool: a restore of an instance onto a rebuilt host was not tried); **ZFS on the real 2 TB disk, which is SMR** ([ADR 0005](0005-storage-layout-and-filesystem.md)): a copy-on-write pool on shingled disks is known to suffer on random writes, and nothing here measures it; **lxcfs**; **rootless Podman**; Quadlet; Immich's multi-container set under Podman (the database over its Unix socket through a bind mount); Jellyfin's `/dev/dri` in a Podman container (gate G2).

### R6. Two pools, as the owner asked (round 2, tag `exp-vms-incus-r2`)

The owner wants most VM disks on the **2 TB SMR disk kept as ext4**, and the SSD's ZFS pool for what needs speed (a database VM). The lab stands in the 2 TB disk with a loop-file ext4 (**it cannot imitate a shingled disk's speed**). All declared in `incus.nix`:

| Check | Result |
|---|---|
| The preseed creates a **directory pool `smr`** (a folder on the ext4 disk) and the **ZFS pool `zp`**, and two profiles: `default` (root on `smr`) and `fast` (root on `zp`) | **yes**; the directory pool needs its folder to exist and the disk mounted first: **`systemd.tmpfiles` and `RequiresMountsFor` on the preseed unit, 2 lines**, or the preseed fails with "Source path doesn't exist" |
| A container and a VM launched **with no option** | both land on **`smr`** |
| The same with **`-p default -p fast`** | both land on **`zp`** |
| Space | the directory pool held 899 MB and the ZFS pool 593 MB after the four instances |
| The publication gate as a **module with an option** (`tidepool.publishGate.allowedPorts = [ ... ]`, default none) in the base configuration | **declared, no manual step**: the table is present at boot with an empty list (**every published port dropped**), and a port appears on the list only by a reviewed line |

What it costs: on the `smr` pool a VM's snapshot is a **full copy** (3.5 s) and a clone **1.2 GB and 11 s** (R5); fine for test machines, which is the use.

## Reading the results against the criteria

1. **Range.** **Incus alone covers all three kinds of workload** in one tool and one set of commands: a VM from a catalogue image, a VM from any installer ISO, a system container, and an application container from an OCI image (pinned by digest). libvirt covers VMs of any system only; microvm.nix only NixOS guests; Podman and Docker only application containers. **No other candidate comes close on range.**
2. **P1 and declaration.** The ranking reverses here. **libvirt through NixVirt and microvm.nix declare their guests in the flake; Incus declares everything around the instances (network, pools, profile with cloud-init, UI, firewall) but not the instances**, which are created by commands and live in Incus's database. For the **tests and throwaway machines** that is the intended use ([ADR 0010](0010-vm-service-exposure.md): "a new or temporary VM needs no change to the flake"); for a machine that **stays** it is a gap, closed by running the things that stay as **services** ([ADR 0011](0011-services.md): native modules or declared Podman containers), which is already the plan, and not as VMs.
3. **Coexistence with a container engine.** Both engines work beside Incus, with the same **10 declared lines**; the real difference is not the engine but the **NixOS firewall's "allow port forward" rule that makes any bare `-p` public**, closed by a 6-line table of ours. Podman writes one table of its own and has no daemon; Docker goes through `iptables-nft`.
4. **The throwaway cycle.** **A ZFS pool makes a VM's snapshot, restore and clone fractions of a second and its clone free of space**; a directory pool copies the disk; thin LVM is in between and needs its kernel modules declared.
5. **Memory and moving parts.** Incus idle: a few hundred MiB with the ZFS pool and no instance; Podman: none while no container runs; libvirt: similar to Incus; microvm.nix: the guests only.

## Decision (2026-10-02, confirmed by the owner)

**Incus as the one manager for tests, with its pool on ZFS; Podman for the containers that stay; neither Docker nor libvirt nor microvm.nix.**

- **Incus** (`virtualisation.incus`, the preseed holding the bridge, the pools, the default profile with the owner's cloud-init, the UI on the VPN address only): VMs of any system, system containers and **OCI application containers** all from it. Docker is **not** needed for "containers for tests": `incus launch docker:<image>` runs them.
- **Podman, not Docker, for the service containers** of [ADR 0011](0011-services.md) (Jellyfin, Immich): `virtualisation.oci-containers` with the Podman backend, images **pinned by digest**, ports written with an address, no Compose file. This meets the owner's preference and **costs nothing the lab could measure**: the same 10 declared lines, no daemon, one table. **Docker is dropped**, and [the host specification's H04](../specs/host.md) ("Docker Engine answers, the Compose plugin is present") changes to Podman.
- **The publication gate** (a module of `exp/vms-incus`, `publish-gate.nix`, **declared in the flake**, evaluated before the NixOS firewall's own rule; nothing is done by hand): **a port is public only if it is on a reviewed list**, for Podman, for Incus's declared DNAT and for anything else. This is [ADR 0010](0010-vm-service-exposure.md)'s principle enforced against the engines' default; **it replaces trusting each `-p`**.
- **Two pools, both declared:** **`zp`, ZFS on the SSD**, for what needs speed (a VM that runs a database, anything "clean and calm": instant snapshot, restore and clone, a clone free of space), chosen per instance with the `fast` profile (`incus launch ... -p default -p fast`); and **`smr`, a plain directory pool on the 2 TB disk, which stays ext4**, the **default** for every other instance: no copy-on-write on a shingled disk, which answers the worry above. Size of the SSD's share for VMs is a quota to set when the SSDs are bought ([ADR 0005](0005-storage-layout-and-filesystem.md)).
- **libvirt with NixVirt is the fallback** for a VM of another system that must be **declared and permanent** (it declares any-OS domains in the flake, which Incus cannot); **microvm.nix** is the fallback for a NixOS service that should be a VM (declared, lightweight). Neither is adopted now because no use case needs them, and each would be a second manager.

**Consequences and what stays open.**
- **The instances' definitions live in Incus's database** (`/var/lib/incus`), the disks in the pool: **both must be in the backup** ([ADR 0004](0004-backup.md)), and **a restore of an instance onto a rebuilt host is untested**; it belongs to the drill of phase 7. v0's `incus_config_backup.sh` is glue that this replaces only once that restore is shown.
- **The 2 TB SMR disk is not given a copy-on-write pool**: it carries an ext4 directory pool, so the known ZFS-on-SMR weakness is avoided by design. **How slow that disk is for a VM is not measured** (the lab's loop file is a plain ext4 on a fast disk); the first real VMs on it will show it, and the `fast` profile is the escape for any instance that suffers.
- A VM stop issued right after its first boot **hung for 600 s** in the lab (not diagnosed); on the real machine the first stop of a new VM is to be watched.
- `lxcfs` (so that a limited container reports its limit) is **a declared line, untested**.
- The real checks at deployment: Jellyfin's `/dev/dri` and Immich's machine learning in **Podman** containers (gate G2), the Immich set (database over its Unix socket through a bind mount), Podman's behaviour across a reboot.
