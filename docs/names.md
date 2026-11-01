# The names

One domain (`tidepool.domain` in the private `host.nix`), one wildcard certificate (`*.domain`, [ADR 0008](decisions/0008-edge.md)). Each service has a name by **what it is for**, not by the program behind it, so that changing the program does not change the address. The names are in [`nixos/modules/edge.nix`](../nixos/modules/edge.nix).

## Public (the router forwards 80 and 443)

| Name | For | Program |
|---|---|---|
| `cloud.` | files, calendar, contacts, the single sign-on of the others | Nextcloud |
| `photos.` | photos and videos | Immich |
| `media.` | films, series, music | Jellyfin |
| `vault.` | passwords | Vaultwarden |
| `backup.` | the phones' backup destination (WebDAV, password) | nginx WebDAV |
| `push.` | push notifications | ntfy |

## Only through the VPN (the name listens on the WireGuard address 10.100.0.1)

| Name | For | Program |
|---|---|---|
| `sync.` | the synchronisation's web page | Syncthing GUI |
| `metrics.` | the measurements and their queries | Prometheus |
| `alerts.` | the alerts' state and silences | Alertmanager |
| `compute.` (port 8443) | machines and containers | Incus |
| `admin.` | the page that lists these tools and the services, with a status for each (on by default, reached once the DNS record exists; `tidepool.admin.enable = false` leaves it out: [ADR 0021](decisions/0021-admin-page.md)) | Homepage |

Incus is the exception: it keeps its own TLS and client certificates, so nginx does not stand in front of it. Point `compute.<domain>` at 10.100.0.1 and open `https://compute.<domain>:8443`.

SSH is on the VPN too (port 2222, [ADR 0009](decisions/0009-remote-access-vpn.md)); `ssh.<domain>` pointing at 10.100.0.1 is a convenience, not a requirement.

## The Incus instances (off until the DNS below exists: `tidepool.compute.names.enable`)

| Name | Reaches | Visible from |
|---|---|---|
| `<instance>.compute.` | **port 80** of any Incus instance (VM, system container, application container), as plain HTTP behind nginx's TLS | **the VPN only** |
| the same, for an instance listed in `tidepool.compute.public` | the same | the Internet too |

Nothing else of an instance is published: its other ports and SSH go through the VPN, which routes the instances' subnet (10.100.1.0/24; the client's `AllowedIPs` must include it).

**SSH by name.** Incus's own DNS answers `<instance>.incus` for every instance, but only on its bridge. With `tidepool.compute.names.enable` the server offers that DNS on the VPN address (10.100.0.1, port 53, handed over by nginx; checked in the lab with a container). A device sends **only the `.incus` names** there, and then `ssh <user>@alpha.incus` works while the VPN is up (not tried on a real client):

- **Linux with systemd-resolved:** `resolvectl dns <wireguard interface> 10.100.0.1` and `resolvectl domain <wireguard interface> '~incus'` (a `PostUp` line of the WireGuard configuration makes it stick).
- **macOS:** a file `/etc/resolver/incus` holding `nameserver 10.100.0.1`.
- **Android and others without a per-domain resolver:** use the instance's address (`incus list`, or the UI at `compute.<domain>:8443`).

A name that is nobody's (an unknown host, or `a.b.compute.<domain>`) gets **no answer**, on the public addresses and on the VPN address: over HTTPS the handshake is refused (no certificate is shown), over HTTP the connection is closed. An unknown instance under `compute.` answers 502. Podman containers (Jellyfin, Immich) are not Incus instances and have their own names above.

## Names from inside the home network (the "hairpin" problem)

The public names resolve to the home's public address. A device inside the home that asks for one goes out to that address and has to come back in through the router, which a number of home routers do not allow (NAT loopback, "hairpin"): the page does not open at home but opens on mobile data. Three cases:

- **The machine itself** (a program on it asking for one of its own names: Immich logging in at `cloud.<domain>`, the push bridge, a browser on the TV session): **solved in the configuration.** `modules/edge.nix` makes every virtual host's name resolve on the machine to the machine (the public names to the loopback, the VPN-only ones to `10.100.0.1`), taken from nginx itself so that a name added later follows. The lab has a DNS that answers 127.0.0.1 for the same purpose.
- **Another device of the home network.** The machine cannot fix it: the device asks the router's DNS. To find out whether it is a problem, from a device on the home Wi-Fi with the VPN off: `curl -I https://photos.<domain>`. If it answers, there is nothing to do. If it hangs, one of these, in this order: (1) the router's own DNS: a local record (many routers call it "local DNS", "host override" or "static DNS") for each public name, pointing at the machine's address in the home network; (2) the device's `hosts` file with the same lines (one line per name, the machine's home address first), device by device; (3) use the names only away from home or through the VPN. A name that is **VPN-only** (`admin.`, `sync.`, `metrics.`, `alerts.`) resolves to `10.100.0.1` for everyone and answers only through the tunnel; that is the design (ADR 0009), not the hairpin.
- **The VPN itself.** The tunnel's endpoint is the dynamic-DNS name, so a device at home that starts the tunnel meets the same problem (UDP 51820). At home, give the device a profile whose endpoint is the machine's home address (the port is open on every interface), or leave the tunnel off while at home (the public names then need the router's DNS or the `hosts` lines above).

## What the DNS provider needs

- **Public names:** the address of the house (an A record, or a CNAME to the dynamic-DNS name) for each of the six; a wildcard record covers them.
- **VPN names:** `sync`, `metrics`, `alerts`, `compute`, `admin` (and `ssh`) as A records to **10.100.0.1**, a private address that only means something inside the VPN. The certificate is valid for them all, so the browser shows no warning.
- **The instances' zone:** a CNAME `_acme-challenge.compute` to the acme-dns name of a registration made for it (like the main domain's), **and that registration's credentials added, under the key `compute.<domain>`, to the secret `acme-dns-credentials` of the private repository** ([the template's step 8](../private-repo-template/README.md); the certificate's order looks them up by the zone's name, and without them it fails), `compute` and `*.compute` as A records to **10.100.0.1**, and, for **each public instance**, its own A record to the house's address (it wins over the wildcard: a wildcard cannot be VPN and public at once). The CAA record's `issuewild` already allows the second wildcard.
- A new name is a line in `edge.nix` and, for a VPN one, a DNS record: the certificate needs nothing.
