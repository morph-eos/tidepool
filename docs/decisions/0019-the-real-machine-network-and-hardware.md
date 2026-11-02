# 0019. The hardware module, WiFi as the link, and the SSD's interface

- **Status:** accepted; measured in the lab with a virtual radio, not on a real card
- **Date:** 2026-10-05
- **Phase:** 9, Deployment preparation

## Context

[ADR 0005](0005-storage-layout-and-filesystem.md) describes the kind of machine this flake targets: a UEFI desktop board with an Intel CPU, a WiFi card, a 2.5 GbE port, a discrete GPU and the platform's firmware TPM. Two things were open when preparing the first deployment. The Ethernet cable may not be connected, so the machine would be on WiFi. And the SSD for the services may be SATA or NVMe. Looking at what the flake knew about real hardware showed a third thing: nothing.

## 1. The flake had no hardware configuration

`hosts/tidepool` imported only the example values. There was no firmware (the WiFi card needs its firmware blobs and the GPU its own: without them neither works), no microcode, no `kvm-intel`, no TPM driver in the initrd (the disks are opened there), and no network configuration at all outside the lab.

Added: `modules/hardware.nix`, switched by `!tidepool.lab`: `hardware.enableRedistributableFirmware`, Intel microcode, `kvm-intel`, `ahci nvme sd_mod xhci_pci usbhid tpm_crb tpm_tis` in the initrd, DHCP. The lab host does not get it (checked: `updateMicrocode` is false there, true on the example host).

## 2. WiFi: is it a problem?

A good 5 GHz link gives hundreds of Mbit/s with a few milliseconds of latency, which is plenty for the services. One setting is wrong for a server and is often on by default on desktop systems: the radio's power saving, which adds latency and drops.

Verdict: not a blocker. What the services need is small (the web names, Syncthing, the VPN's UDP port, the NAS on the LAN). The router's port forwards point at the machine's address, which comes from a reservation by the card's address and does not change when the system does.

What it costs: the NAS and Time Machine are slower than on a cable, because WiFi shares the air; the machine depends on the access point and on the radio environment; and a network that is down is a machine that cannot be reached from outside (the heartbeat to Healthchecks.io then stops and says so, [ADR 0012](0012-observability.md)). Nothing in the flake depends on the cable: only the LAN interface's name does.

Built: `modules/wifi.nix` (off by default, `tidepool.wifi.enable`). `wpa_supplicant` through the NixOS module, the network's name and the interface as private values, the key a sops secret (`wifi-psk`, one line `psk_home=<64 hex digits from wpa_passphrase>`), the radio's power saving turned off by a udev rule, DHCP on that interface, and `tidepool.lanInterface` set to it (Samba and Avahi follow).

To use a cable instead: remove `wifi`, set `lanInterface` to the Ethernet interface's name, and update the router's reservation to the Ethernet port's address (it is by the card's address, and the two cards have different ones).

## 3. Measured in the lab

`lab/experiments/wifi-u23.sh`: a pair of virtual radios (`mac80211_hwsim`), a real hostapd access point (WPA2) and a DHCP server in a network namespace, and the lab host connecting to it with the module. The access point is started after the activation, as a router is after a boot.

| Result | |
|---|---|
| The host associates (WPA2, CCMP) and gets an address by DHCP | works |
| The key is not in the Nix store; the unit's config says `psk=ext:psk_home` | works |
| The NAS from another device on the WiFi (the access point's side) | the shares are listed; a file was written and read back |
| The firewall | 445 accepted on the WiFi interface only |

Three defects, found by the test and fixed:

1. `psk = "ext:..."` does not work. The NixOS module writes it with quotes, `wpa_supplicant` reads a literal passphrase and the handshake fails ("pre-shared key may be incorrect"). The module needs `pskRaw = "ext:..."` and the 64-digit key, which is derived from the name and the passphrase (`wpa_passphrase`).
2. The secret must belong to `wpa_supplicant`. The service runs as its own user: with sops' root-only file it logged "could not open file ... Permission denied". Also a changed secret did not restart the unit (a new passphrase would have been ignored): `restartUnits` is set.
3. Samba fixed its addresses at its start. With `bind interfaces only` it started before the WiFi had an address, stayed "active", never listened on the WiFi address (ping answered, SMB timed out), and `nmbd` timed out and failed. `bind interfaces only` is off (the firewall already lets 445 in on the LAN interface only), and the Samba units wait for `network-online.target` and retry on failure. This changes [ADR 0017 section 4](0017-version-watch-push-and-nas.md): the NAS no longer relies on Samba's own address binding.

Not tried in the lab: a real radio (the card's firmware, WPA3 or 6 GHz, how fast the card reconnects after the router restarts), throughput over the air, the power-saving rule on a real card (the virtual radio reports "off" with or without it), the boot order on real hardware (the late access point simulates it), and Time Machine over WiFi.

## 4. The SSD's interface: SATA or NVMe

Nothing in the design depends on the interface. The initrd already loads `ahci` and `nvme`; the layout is whole-disk GPT, LUKS, ZFS with `ashift` 12 and weekly trim, and the trim reaches the drive through LUKS. The stable path is `/dev/disk/by-id/ata-<model>_<serial>` or `nvme-<model>_<serial>` (or `wwn-...`), the same wherever the drive is plugged.

- A SATA drive needs a free SATA port and a power connector; an NVMe one needs an M.2 slot, and which slot is wired to the CPU or the chipset is for the board's manual.
- Speed: about 500 MB/s against about 3 GB/s, which the services do not feel (the link to them is the network, and the databases are small). Latency for the database and the `fast` Incus pool is a little higher on SATA.
- Endurance: a 1 TB consumer SSD of this class is rated for hundreds of TB written, against a few GB a day here.
- Like most consumer SSDs it has no power-loss protection, on either interface: ZFS sends cache flushes, and the backups cover the rest.
- A later mirror wants a drive of the same size in bytes, of either interface (`zpool attach` accepts a mixed pair; synchronous writes then go at the slower one's speed).
- Before use, if the drive is second-hand: read its SMART data (hours, bytes written, reallocated sectors) and write and read back its whole capacity once (`f3write` and `f3read`) before it holds anything. The alerts of [ADR 0012](0012-observability.md) watch it afterwards.

## 5. WiFi is a supported permanent link, not a stopgap

The cable is optional and I do not plan to connect one; the design does not push towards it. The `wifi` block and `lanInterface` are all the flake needs, and the "with a cable" steps of section 2 remain the way to change one's mind.

- Rules that depend on the interface by name: the SSH port is also open on the WiFi interface, from the home network only (a forwarded port arrives on that same interface, so the interface alone would also let the router's forwards in); the NAS and Avahi follow `lanInterface`. A change of interface needs those lines changed together.
- Seen on real hardware: the firmware loads, the machine reconnects at every boot, the interface counts no receive or transmit error, and a large sustained upload ran at 100 Mbit/s or more while the services kept working.
- Still to try: the reconnection after a router restart (the address comes from a reservation by the card's address, so it should come back by itself), the radio's power saving read on the live card (`iw` is not installed by default), and Time Machine over the air once it is switched on. The heartbeat to the outside service says so if the machine drops off the network.

## Consequences

- `modules/hardware.nix` and `modules/wifi.nix`; the private template turns the WiFi on and says how to compute the key; `nas.nix` changed as above.
- [Pending](../pending.md): the SSD's by-id path at fitting time, the router's reservation, the radio on a real card.
