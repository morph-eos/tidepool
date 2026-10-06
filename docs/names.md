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

## What the DNS provider needs

- **Public names:** the address of the house (an A record, or a CNAME to the dynamic-DNS name) for each of the six; a wildcard record covers them.
- **VPN names:** `sync`, `metrics`, `alerts`, `compute` (and `ssh`) as A records to **10.100.0.1**, a private address that only means something inside the VPN. The certificate is valid for them all, so the browser shows no warning.
- A new name is a line in `edge.nix` and, for a VPN one, a DNS record: the certificate needs nothing.
