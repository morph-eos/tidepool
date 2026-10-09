# 0019. The real machine: its hardware module, WiFi until the cable, and the 1 TB SSD

- **Status:** accepted by the owner (2026-10-05) for the WiFi and the SSD; **measured in the lab with a virtual radio, not on the real card**
- **Date:** 2026-10-05
- **Update 2026-10-09:** the SSD bought is a **2.5-inch SATA drive**, not NVMe (section 4); the decision stands.
- **Phase:** 9, Deployment preparation

## Context

[ADR 0005](0005-storage-layout-and-filesystem.md) records what the machine is (a UEFI desktop board with an Intel CPU, a WiFi card, a 2.5 GbE port, a discrete GPU and the platform's firmware TPM; the exact models are in the private repository). Two things changed on 2026-10-05: **the Ethernet cable cannot be connected for now** (the machine is on WiFi, as it is today under Ubuntu), and **the new SSD is a 1 TB NVMe drive** (not 500 GB), still on its way. Looking at what the flake knew about the real machine showed a third thing: **nothing**.

## 1. The flake had no hardware configuration

`hosts/tidepool` imported only the example values. There was **no firmware** (the WiFi card needs its firmware blobs and the GPU its own: without them neither works), **no microcode**, no `kvm-intel`, **no TPM driver in the initrd** (the disks are opened there), and **no network configuration at all** outside the lab. Added: **`modules/hardware.nix`**, switched by `!tidepool.lab`: `hardware.enableRedistributableFirmware`, Intel microcode, `kvm-intel`, `ahci nvme sd_mod xhci_pci usbhid tpm_crb tpm_tis` in the initrd, DHCP. The lab host does not get it (checked: `updateMicrocode` is false there, true on the example host).

## 2. WiFi: is it a problem?

**What the link is, measured on the machine today (read only):** 5 GHz, signal **-51 dBm**, **960 Mbit/s** in both directions (802.11ax, 80 MHz, 2x2), **2.7 ms** average to the router and **0 % loss** in 20 pings. **Power saving on the radio is on** (Ubuntu's NetworkManager sets it), which is wrong for a server: it adds latency and drops.

**Verdict: not a blocker.** What the services need is small (the web names, Syncthing, the VPN's UDP port, the NAS on the LAN); the router's port forwards point at the machine's address, which comes from a reservation by the card's address and does not change when the system does. **What it costs:** the NAS and Time Machine are slower than on a cable (the link is fast, but WiFi shares the air); the machine depends on the access point and on the radio environment; a network that is down is a machine that cannot be reached from outside (the heartbeat to Healthchecks.io then stops and says so, [ADR 0012](0012-observability.md)). **Nothing in the flake depends on the cable**: only the LAN interface's name does.

**Built: `modules/wifi.nix`** (off by default, `tidepool.wifi.enable`): `wpa_supplicant` through the NixOS module, the network's name and the interface as private values, the **key a sops secret** (`wifi-psk`, one line `psk_home=<64 hex digits from wpa_passphrase>`), the radio's **power saving turned off** by a udev rule, DHCP on that interface, and **`tidepool.lanInterface` set to it** (Samba and Avahi follow). With the cable: remove `wifi`, set `lanInterface` to the Ethernet interface's name, **update the router's reservation to the Ethernet port's address** (it is by the card's address, and the two cards have different ones).

## 3. Measured in the lab (`lab/experiments/wifi-u23.sh`)

A pair of **virtual radios** (`mac80211_hwsim`), a **real hostapd access point (WPA2) and a DHCP server** in a network namespace, and the lab host connecting to it with the module. The access point is started **after** the activation, as a router is after a boot.

| Result | |
|---|---|
| The host associates (WPA2, CCMP), gets **192.168.77.17 by DHCP** | works |
| The key is **not** in the Nix store; the unit's config says `psk=ext:psk_home` | works |
| The NAS from "another device on the WiFi" (the access point's side) | the shares `NAS` and `TimeMachine` are listed; **a file was written and read back** |
| The firewall | **445 accepted on the WiFi interface only** |

**Three defects, found by the test and fixed:**

1. **`psk = "ext:..."` does not work.** The NixOS module writes it **with quotes**, `wpa_supplicant` reads a literal passphrase and the handshake fails ("pre-shared key may be incorrect"). The module needs **`pskRaw = "ext:..."` and the 64-digit key**, which is derived from the name **and** the passphrase (`wpa_passphrase`).
2. **The secret must belong to `wpa_supplicant`.** The service runs as its own user: with sops' root-only file it logged "could not open file ... Permission denied". Also **a changed secret did not restart the unit** (a new WiFi passphrase would have been ignored): `restartUnits` is set.
3. **Samba fixed its addresses at its start.** With `bind interfaces only` it started before the WiFi had an address, stayed "active", **never listened on the WiFi address** (ping answered, SMB timed out), and `nmbd` timed out and failed. **`bind interfaces only` is off** (the firewall already lets 445 in on the LAN interface only), and the Samba units **wait for `network-online.target` and retry on failure**. This changes [ADR 0017 section 4](0017-version-watch-push-and-nas.md): the NAS no longer relies on Samba's own address binding.

**Not tried, and worth knowing:** a **real radio** (the card's firmware, WPA3 or 6 GHz, how fast the card reconnects after the router restarts); **throughput** over the air; the **power-saving rule on the real card** (the lab's virtual radio reports "off" with or without it); the boot order on the real machine (the late access point simulates it); **Time Machine over WiFi**.

## 4. The SSD: 1 TB (planned as NVMe, fitted as SATA)

**Update 2026-10-09: the drive is a 2.5-inch SATA SSD, not an M.2 NVMe one.** Everything below holds, with these differences, checked in the flake: **nothing in it depends on the interface** (the initrd already loads `ahci`, the system disk is SATA too; the layout is whole-disk GPT, LUKS, ZFS with `ashift` 12 and weekly trim, and the trim reaches the drive through LUKS); the stable path is `/dev/disk/by-id/ata-<model>_<serial>` (or `wwn-...`), **the same wherever the drive is plugged**; it takes **a free SATA port and a power connector and no M.2 slot**. **Speed:** about 500 MB/s against about 3 GB/s, which the services do not feel (the link to them is the WiFi, about 100 MB/s, and the databases are small); latency for the database and the `fast` Incus pool is a little higher. **Endurance:** a 1 TB SATA SSD of this class is rated for hundreds of TB written, against a few GB a day here. **Like most consumer SSDs it has no power-loss protection**, which holds for the NVMe one as well: ZFS sends cache flushes, and the backups cover the rest. **A later mirror** wants a drive of the same size in bytes, of either interface (`zpool attach` accepts a mixed pair; synchronous writes then go at the slower one's speed). **Check before use:** it may be second-hand or from a marketplace, so read its SMART data (hours, bytes written, reallocated sectors) and write and read back its whole capacity once (`f3write` and `f3read`) before it holds anything; the alerts of [ADR 0012](0012-observability.md) watch it afterwards. The text that follows is the original plan.

An NVMe M.2 drive, on its way. The plan of [ADR 0005](0005-storage-layout-and-filesystem.md) was one SSD of about 500 GB for the ZFS pool of the services; **1 TB changes nothing in the design and relaxes the margins**: the services' data is about 165 GB and grows about 4 GB a month, the databases are a few GB. It becomes **`tidepool.disks.tank`** by its stable path, `/dev/disk/by-id/nvme-<model>_<serial>`, **known when it arrives** (`ls -l /dev/disk/by-id | grep nvme`). The layout (LUKS under the pool, `ashift` 12, trim) is unchanged; **a mirror later would want a second drive of at least the same size**. The board has M.2 slots; **which one is free and whether it is wired to the CPU or the chipset** is for the owner to read in the manual when fitting it (the drive runs at its own PCIe 3.0 speed in either).

## Consequences

- `modules/hardware.nix` and `modules/wifi.nix`; the private template turns the WiFi on and says how to compute the key; `nas.nix` changed as above.
- [Pending](../pending.md): the SSD's by-id path when it arrives; the router's reservation; the radio on the real card.
