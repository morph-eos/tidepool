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

Incus is the exception: it keeps its own TLS and client certificates, so nginx does not stand in front of it. Point `compute.<domain>` at 10.100.0.1 and open `https://compute.<domain>:8443`.

SSH is on the VPN too (port 2222, [ADR 0009](decisions/0009-remote-access-vpn.md)); `ssh.<domain>` pointing at 10.100.0.1 is a convenience, not a requirement.

## The Incus instances (off until the DNS below exists: `tidepool.vms.names.enable`)

| Name | Reaches | Visible from |
|---|---|---|
| `<instance>.compute.` | **port 80** of any Incus instance (VM, system container, application container), as plain HTTP behind nginx's TLS | **the VPN only** |
| the same, for an instance listed in `tidepool.vms.public` | the same | the Internet too |

Nothing else of an instance is published: its other ports and SSH go through the VPN, which routes the instances' subnet (10.100.1.0/24; the client's `AllowedIPs` must include it). With the VPN up, `ssh <user>@<instance address>` works from any device; the address is in `incus list` or in Incus's UI at `compute.<domain>:8443`. **Names for SSH are not built:** the bridge's DNS (`<instance>.incus`) answers only nginx and the instances, not the server's own resolver nor a VPN client (its port is closed on the VPN interface). A line per instance in the laptop's `~/.ssh/config` (`Host alpha` with `HostName 10.100.1.x`) does it today. Podman containers (Jellyfin, Immich) are not Incus instances and have their own names above.

## What the DNS provider needs

- **Public names:** the address of the house (an A record, or a CNAME to the dynamic-DNS name) for each of the six; a wildcard record covers them.
- **VPN names:** `sync`, `metrics`, `alerts`, `compute` (and `ssh`) as A records to **10.100.0.1**, a private address that only means something inside the VPN. The certificate is valid for them all, so the browser shows no warning.
- **The instances' zone:** a CNAME `_acme-challenge.compute` to the acme-dns name (with the registration, as for the main domain), `compute` and `*.compute` as A records to **10.100.0.1**, and, for **each public instance**, its own A record to the house's address (it wins over the wildcard: a wildcard cannot be VPN and public at once). The CAA record's `issuewild` already allows the second wildcard.
- A new name is a line in `edge.nix` and, for a VPN one, a DNS record: the certificate needs nothing.
