# 0009. Remote access: a personal VPN

- **Status:** accepted (2026-10-01): plain WireGuard through the NixOS module; Tailscale as the fallback; the split public / VPN-only is in [ADR 0008](0008-edge.md)
- **Date:** 2026-10-01
- **Phase:** 3, Edge (it answers "what is reachable from outside, and how")

## Context

In v0 the router forwards **80, 443 and the range 3000-3099** to the server, so the Internet reaches the web services, the ports of every VM that listens in that range, and, through an SNI passthrough, the **Incus API with its client-certificate login**. SSH is on 2222 with a router rule that is meant to stay closed except for maintenance. The router is the only firewall (UFW is off).

The owner's direction ([ADR 0008](0008-edge.md)): split the services into **those that must be reachable from anywhere** (the phone apps and the family's services) and **those that only need to be reachable through a VPN** (the Incus UI and API, Syncthing's GUI, the router's page, the personal site, and SSH), and asked how to set up **a personal VPN** for it.

## Requirements

- **Must:** a device outside the house reaches the VPN-only names and ports; **nothing else does**, including the VPN-only names on the public address; only the devices of the owner and the family are admitted (a lost device can be removed); the keys are not in the Nix store ([ADR 0003](0003-secrets.md)); it comes up at boot with no one present.
- **Should:** a maintained NixOS module and no third party in the path; adding a device is a few lines in the flake; phone clients are easy (a QR code); it works with a dynamic IP (the DDNS name of v0).
- **Won't:** a VPN for all of the family's traffic (a full tunnel to the house); a corporate access system.

## Options considered

| Option | What it is | NixOS module |
|---|---|---|
| **A. Plain WireGuard** | the kernel's WireGuard, one UDP port forwarded on the router, keys and peers in the flake | `networking.wireguard` (and `networking.wg-quick`) |
| **B. Tailscale** | WireGuard with automated keys, **NAT traversal** and names; the coordination server is **Tailscale Inc.'s** | `services.tailscale` |
| **C. Headscale with Tailscale's clients** | the same clients, with the coordination server **run by the owner** | `services.headscale` (and `services.tailscale` for the server's own client) |
| NetBird | a similar mesh, with its own clients | `services.netbird` (not considered further) |

What the comparison sites say ([serverside](https://serverside.com/blog/wireguard-vs-tailscale-vs-headscale-vs-netbird), [VPNSmith](https://www.vpnsmith.com/en/blog/best-self-host-vpn-2026); not tested here): plain WireGuard is the right answer for **a small, static setup** and needs manual key handling; Tailscale wins on time to value and on **carrier-grade NAT**, where no inbound port can be opened; Headscale keeps the control plane at home at the cost of more to run. **The owner has port forwarding today (80 and 443 reach the server), so an inbound UDP port works**: the case where plain WireGuard is hardest does not apply.

## Results

`lab/vpn-bakeoff.sh` in the NixOS lab VM (`exp/vpn-wireguard`): the server's WireGuard through `networking.wireguard` with **one peer**; a network namespace stands for a **phone on the VPN**, another for **the outside** (joined by a virtual cable, so its traffic arrives on a real interface; the first version of this test came from the machine itself, whose traffic goes through the loopback, which the firewall always lets through, and its results were thrown away).
A name **`admin.lab.test` listens only on the WireGuard address**; a port **7777** (standing for SSH) is open **only on `wg0`**; the public names go through the usual SNI front end on the LAN address; **unknown names are rejected at the TLS handshake** (a default virtual host with `rejectSSL`).

| Check | Result |
|---|---|
| V1. The handshake with the listed peer | **yes** (4 s) |
| V2. The VPN-only name through the VPN | **answers**, and the backend sees the **peer's VPN address** as the client (`x-real-ip` 10.100.0.2) |
| V3. The same name from outside | **no answer**: the TLS handshake is refused (curl exit 35) |
| V4. A public name from outside | **answers**, with the real outside address as the client |
| V5. The VPN-only port 7777 | **answers through the VPN, silent from outside** (the firewall drops it) |
| V6. A peer whose key is not in the configuration | **nothing**: it cannot even reach the open port, because the server ignores unknown keys |
| Our own configuration | **20 lines** for the interface, one peer, the firewall rules and the ordering below; **3 lines more for each device** |

What running it showed:
- **nginx must start after the WireGuard interface** (`after` and `requires` on `wireguard-wg0.service`, two lines), or it fails to bind the VPN address.
- **WireGuard does not answer packets from unknown keys**, so the UDP port looks closed to a scan; that is a property of the protocol, from the documentation, not measured here.
- **In this lab, when one certificate order failed at boot, the other orders were skipped with `Dependency failed` and the names stayed on the module's placeholder certificates until the orders were started again** (`reset-failed`, then a start; the renewal timers run **daily with a random delay of up to 24 hours**, measured on 2026-10-03: an earlier version of this line said every 12 hours). That is a weakness of the ACME module's ordering that matters here because a **VPN-only name cannot get its certificate by HTTP-01** (see below); it needs an alert (phase 5).
- A lab error of mine, kept because it recurs in real configurations: a name resolved through `/etc/netns/.../hosts` does not work on NixOS (`/etc/hosts` is a symbolic link); use `curl --resolve`.

**Certificates for VPN-only names.** HTTP-01 needs the name to reach the server on port 80 **from the Internet**, which a VPN-only name must not. Options: **DNS-01** (the DNS provider's API, the credentials as a sops secret; the NixOS ACME module and Traefik support many providers natively) or a **private CA** for the internal names (a step-ca, one more service). The DNS is at a provider that `lego` does not support: the routes are in [ADR 0008](0008-edge.md).

**Not tested:** a real phone and roaming between networks; how a client behaves when the server's address changes (clients resolve the endpoint name when the tunnel starts or reconnects); throughput and MTU; IPv6; **Tailscale and Headscale** (a Tailscale account, a second machine and a real network are needed); DNS for the VPN names on the client side (a private DNS on the VPN, or the public DNS holding the VPN address).

## Criteria, in this order

1. **P1:** a maintained module, no third party in the path, the keys as secrets, nothing done by hand in steady state.
2. **The split holds** (measured): VPN-only names and ports unreachable from outside, public ones unaffected, unknown names refused.
3. **Admission and revocation:** how a device is added and removed.
4. **Works where the owner is:** a public address and port forwarding today; what happens behind CGNAT.
5. **Moving parts and the owner's effort per device.**

## Decision (2026-10-01, confirmed by the owner)

**A, plain WireGuard through the NixOS module.**
- It meets criterion 1 with **20 lines and no third party**; the split of criterion 2 holds in every check; adding a device is **3 lines** and a key pair generated on the device (a QR code for a phone), and removing it is deleting the lines.
- **The owner's port forwarding makes it work**: one UDP port on the router, in place of the range 3000-3099 and the Incus API that v0 exposes.
- **Fallback: Tailscale** (`services.tailscale`), if the house ever sits behind carrier-grade NAT or the owner prefers a zero-maintenance phone experience; its cost is that the coordination server is a third party (and a Tailscale account), which Headscale removes at the price of running it. Switching later is a change of the module, not of the design (the VPN-only names listen on the VPN address in both).

**The design, whichever product:**
- **Public names** (the owner's list): nginx on the LAN address, as in [ADR 0008](0008-edge.md).
- **VPN-only names**: nginx listens on **the VPN address only**; **SSH and every other administration port**: open on the VPN interface only (`networking.firewall.interfaces.wg0`), **closed on the others**, which replaces v0's router rule that is "kept closed unless needed".
- **Unknown names** are refused at the handshake.
- **The router forwards 80, 443 and one UDP port**; the range 3000-3099 and the Incus API are **not** forwarded; whether VM services are published is phase 6.
- **Admission:** each device has its own key and address in the flake; the private key of the server is a sops secret, the public keys are not secret.

## Consequences

- A phone that must reach VPN-only names needs the VPN to be **on**; the public apps (Immich, Nextcloud, Vaultwarden, and whatever else the owner lists) do not.
- Losing the server's private key means every device is re-enrolled; it is in [the custody](0003-secrets.md) with the others.
- The VPN-only names need DNS-01 or a private CA (open question 3), and a **certificate failure must be noticed**, because the placeholder certificate stays in place silently (phase 5).
