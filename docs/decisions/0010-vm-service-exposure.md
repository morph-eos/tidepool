# 0010. How the services of virtual machines reach the outside

- **Status:** accepted (2026-10-01): a VM service is private by default and public only by a line in the flake; the choice of the VM manager itself belongs to phase 6
- **Date:** 2026-10-01
- **Phase:** 3, Edge (with phase 6, Network and VMs)

## Context

In v0 the virtual machines run on Incus, on a bridge (`incusbr0`). **A hook runs every 30 seconds and publishes every listening port in the range 3000-3099 of every VM** through `socat` proxies, driven by `user.proxy.*` keys, and **the router forwards that whole range to the Internet**; the SSH ports 2201-2299 are published on the host as well, and the Incus API listens on `0.0.0.0` with an SNI passthrough from the Internet. There is no host firewall. In short: **a service that starts inside a VM becomes public by itself**, and nothing in the repository says which ones are meant to be.

The owner's wish: it would be nice to have some VM ports reachable from the Internet, and not only through the VPN, but he suspects that would make the configuration much more complicated and less clean; he asked for a study of the modes. His VMs are, in 90% of the cases, **tests and temporary services**.

## Requirements

- **Must:** nothing in a VM is public **by accident**: a VM service reaches the Internet only because a reviewed line in the flake says so; the VMs are reachable by the owner through the VPN, **any protocol** (SSH, databases, whatever the test needs); a new or temporary VM works **with no change to the flake**; no script that watches the VMs.
- **Should:** names for the VMs' web services; a public VM service (a web page, a game server) is possible, declared and in code; the host firewall is the gate; the Incus API only on the VPN.
- **Won't:** an automatic publication of ports; a hand-run command per VM as the way to expose anything.

## Modes considered

| Mode | What it is |
|---|---|
| **M1. v0's** | a range of ports forwarded by the router, a hook with proxies that exposes whatever listens |
| **M2. The VM subnet through the VPN** | the VPN peers get a route to the bridge's subnet and the host forwards for them: every port and protocol of every VM, to the owner only |
| **M3. A name per VM through nginx, on the VPN address** | one wildcard virtual host: `<name>.vm.<domain>` is proxied to `<name>.incus` (the bridge's DNS), listening only on the VPN address |
| **M4. A service published on purpose** | HTTP: an explicit nginx virtual host (public), or raw TCP and UDP: a declared DNAT line to the VM's address |
| **M5. An Incus proxy device** | `incus config device add <vm> ... proxy`: a listener on the host, set by a command and stored in Incus's own database |

## Results

`lab/vm-exposure-bakeoff.sh` in the NixOS lab VM (`exp/vm-exposure`, on top of the VPN experiment of [ADR 0009](0009-remote-access-vpn.md)). **Incus is declared through its NixOS module** (a bridge with managed DNS, a storage pool, the default profile, the API address, all in the preseed);
**containers stand in for VMs** (same bridge, same DNS and DHCP, no nested virtualization needed); a network namespace is "a phone on the VPN" and another is "outside" (joined by a virtual cable, as in ADR 0009).

| Check | Result |
|---|---|
| X1. The bridge's DNS answers for instance names | yes (`beta.incus`) |
| **X2. M3: a name per instance through the VPN** | `alpha.vm.lab.test` and `beta.vm.lab.test` answer; **a third instance created afterwards answered with no configuration anywhere**; the same names from outside: the TLS handshake is refused |
| **X3. M2: the instances' subnet through the VPN** | **every port of an instance answers** (80 and 8081 tested) from the VPN peer; **from outside there is no answer** (the host does not forward) |
| **X4. M4: one port published by a declared DNAT** | the published port **3001 reaches the instance from outside**; **an unpublished port (3002) and the instance's other web port (8081) at the host do not** |
| **X5. M5: an Incus proxy device alone** | it **does listen on the host (3003), but from outside there is no answer**: the NixOS firewall blocks it until a firewall line opens the port, so even this mode needs a line in the flake **and** a command per VM |
| X6. The Incus API on the VPN address | answers through the VPN; **from outside there is no answer** (it does not listen there) |
| Our own configuration | **42 lines** (Incus and its network, the API address, the firewall for the bridge and for the VPN, the forwarding rule, the one DNAT, the wildcard virtual host); **no script** |

What running it showed:
- **The declared firewall is the real gate**: it had to allow **DHCP and DNS on the bridge** (otherwise the instances got no address), the **Incus API port on the VPN interface**, and it forwards only what a rule names. Nothing is open by default, in the opposite of v0.
- **`virtualisation.incus` does not declare instances**: the preseed covers networks, pools and profiles, but a VM or container is created by a command. So **a published port by address needs the instance's address pinned** with one command per instance (`incus config device override <vm> eth0 ipv4.address=...`), which is imperative state in Incus's database. Mode M2 and M3 need no pinning.
- **Docker was left out of this lab** (the module that declares it was removed from the host for this experiment): **Incus and Docker both manage the firewall**, and their rules can conflict. The plan runs services as containers on Docker; **the two together are not tested** and are a phase 6 check.
- **NixOS checks the nftables ruleset when the system is built**: a syntax error in the DNAT rule stopped the build instead of leaving a broken firewall.
- **A wildcard name needs a wildcard certificate**, which needs the DNS challenge: in the lab a fixed certificate was used. For the owner's domain at the DNS provider this is the open problem of [ADR 0008](0008-edge.md).
- The first lab download of Incus's images and packages failed several times over the lab's network and succeeded with more attempts: a lab condition, not a finding.

**Not tested:** real virtual machines (the lab has containers); Incus and Docker on one host; the instances' behaviour at host reboot (the address pin survives it in Incus's database, but the order against the VPN interface is not measured); UDP; a game server or any non-HTTP public service; other VM managers.

## Criteria, in this order

1. **Safe by default (measured):** nothing public unless declared; the owner's access to everything through the VPN.
2. **P1:** declared in the flake, no script, no command per VM for the common case.
3. **A new or temporary VM needs no change to the flake.**
4. **Public services are possible and explicit.**
5. **Lines of our own and moving parts.**

## Decision (2026-10-01, confirmed by the owner)

**A VM service is private by default and public only by a line.**
- **Everything the owner does with a VM goes through the VPN: M2** (the subnet routed over the VPN, with one forwarding rule): SSH, databases, any port, any protocol, **no per-VM configuration**, and it is the answer for the 90% of test and temporary machines.
- **Web names for the VMs' services: M3**, one wildcard virtual host on the VPN address, so `<vm>.vm.<domain>` works as soon as the VM exists; it needs the wildcard certificate (DNS challenge) or a private CA.
- **A VM service that must be public (the few): M4**, an explicit and reviewed line: **a virtual host for a web service**, or **a DNAT line for raw TCP and UDP**, with the VM's address pinned. It is a few lines per service and **it is visible in the flake and in review, which is the point**; it is "more complicated" only in that a public service has to be written down.
- **Not M1** (a range plus a hook: public by accident, and glue) and **not M5** (a command per VM, stored outside the flake, and still needs a firewall line).
- **The Incus API listens on the VPN address only**, so the passthrough of its mutual-TLS login from the Internet, and the relay it needs, **disappear**: nginx no longer needs a stream front end or the PROXY protocol (a simplification for [ADR 0008](0008-edge.md)).
- **The router forwards 80, 443 and the VPN's UDP port**: not 3000-3099, not the SSH ports of the VMs, not the Incus API.

Whether the VM manager stays **Incus** is phase 6: the same design works with any manager whose VMs sit on a bridge with a DNS (for M3) and whose addresses can be declared; a manager that declares its VMs in the flake (microvm.nix, NixOS containers, libvirt) would make M4's address pin declarative too. That comparison has **not** been made.

## Consequences

- A phone that must reach a VM needs the VPN on; nothing about a VM is visible from the Internet unless a line says so.
- The Incus VM disks sit on the 2 TB disk ([ADR 0005](0005-storage-layout-and-filesystem.md)); a VM that matters is a service, not a test machine, and is declared as one.
- Docker and Incus on the same machine had to be tested together: **done in [ADR 0013](0013-vms-and-containers.md)** (both coexist with the same ten declared lines; the NixOS firewall's "allow port forward" rule makes any engine's bare `-p` public, closed by a six-line publication gate; Podman proposed in place of Docker).
