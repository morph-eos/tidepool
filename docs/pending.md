# Pending items

Things deliberately postponed, so they are not lost. Each has an owner decision or a gate behind it. Updated 2026-10-01, after the review of all the ADRs for coherence.

## Waiting for the owner

| Item | Why it waits | Blocks |
|---|---|---|
| **Buy one SSD of about 500 GB** (chosen: [ADR 0005](decisions/0005-storage-layout-and-filesystem.md)); a second one later, as a mirror | the owner's money | the real layout |
| **Create the private repository** for the non-secret variables, and **write the age key and the Borg key exports down** (Proton Pass and paper) | the owner's accounts | closing phase 1 |
| (Only if Proton Drive fails its test) **open the Hetzner Storage Box account** and set its snapshot plan | a subscription and the console | the offsite copy in that case ([ADR 0007](decisions/0007-offsite-copy.md)) |
| **Set a firmware password** (and keep the boot loader's command-line editor off: with lanzaboote on NixOS it is) | the owner will do it | what makes the disk encryption protect a stolen machine ([ADR 0005](decisions/0005-storage-layout-and-filesystem.md)) |
| **The first real checks** of phase 4, at the deployment: a Seedvault backup through nginx's WebDAV, Jellyfin's transcode and Immich's machine learning on the GPU (G2), a login through Nextcloud into Immich, Jellyfin and Vaultwarden (and the SSO plugin and button for Jellyfin), the discovery address answering directly | phase 4, [ADR 0011](decisions/0011-services.md) |
| **Services to carry over to v1** ([ADR 0008](decisions/0008-edge.md)): **Plex and icloudpd are dropped**; Syncthing stays with its sync port public and its GUI VPN-only; Jellyfin, Immich, Nextcloud, Vaultwarden and WebDAV (through nginx) move over; new services come after | phase 4 |
| **Remove the test CNAME `_acme-challenge.test` at the DNS provider** (the two real CNAMEs are in place and served by all four nameservers) | the owner's DNS panel | tidiness |
| **Bind the CAA record to the owner's own ACME account** (`accounturi`), after the first real issuance; check whether the provider's panel accepts CAA | needs the production account's address | hardening of the DNS challenge ([ADR 0008](decisions/0008-edge.md)) |
| **Phase 5: create the Healthchecks.io account and the check** (decided: free plan), and keep its ping address as a sops secret ([ADR 0012](decisions/0012-observability.md)); email only through Brevo is decided | the owner's choice and account | closing phase 5 |
| **Phase 6: decide** the VM manager (proposed: Incus on ZFS), Podman in place of Docker, the publication gate, and **where the VM pool lives** (the 2 TB SMR disk or the new SSDs) ([ADR 0013](decisions/0013-vms-and-containers.md)) | the owner's choice | closing phase 6 |
| **New services to add** next to the v0 ones (for example a replacement for Trakt) | application layer, not infrastructure | phase 4 |


## Deferred on purpose

| Item | Why |
|---|---|
| **Memory**: cap the ZFS cache at about 3 GB; watch the memory pressure counters in the first weeks; add RAM only if they show it ([ADR 0005](decisions/0005-storage-layout-and-filesystem.md)) | phase 5 |
| **Disk replacement on a SMART warning** (an alert from `smartd` or similar): the 16 TB disk now holds the only copy of the media | phase 5 |
| **Self-healing of the primary disk** | deferred by the owner: done properly, with a second SSD attached as a mirror when it can be bought ([ADR 0005](decisions/0005-storage-layout-and-filesystem.md)) |
| **Scheduled ZFS snapshots** | dropped by the owner: the Borg repositories cover what they would undo; can be added later in code ([ADR 0004](decisions/0004-backup.md)) |

## Gates and checks that need the real server or a maintenance window

| Item | What it needs |
|---|---|
| G2, hardware transcoding with ffmpeg in a container | the server installed, a short maintenance window |
| G3b, the Proton Drive CLI keeping its login in a real desktop session or headless | the real machine; part of the Proton Drive test below |
| Health of the small system SSD with `smartctl` | optional: the owner judges it lightly used and easy to replace (S1 ran without root; the v0 `smartcheck` log covers the two HDDs) |

## Lab and design work still to do

| Item | Notes |
|---|---|
| **Proton Drive as the first offsite candidate**: a small container with the official CLI and a repository of our own, tested against the seven criteria of [ADR 0007](decisions/0007-offsite-copy.md) (headless login, unattended and loud on failure, updates, size, restore, deletion, first upload) | one or two phases from now, on NixOS; rclone's Proton backend is unusable; the CLI's help shows only a browser login. Enter it in [the exceptions register](exceptions.md) if adopted |
| The offsite layer against a **real provider** (Hetzner Storage Box over SSH): real throughput, the first 200 GB upload | lab results and prices are in [ADR 0007](decisions/0007-offsite-copy.md); needs an account |
| **The full restore drill on a rebuilt machine** (database and files to the same moment; Borg data also from a Hetzner snapshot, the read-only `/.zfs/snapshot` path) | phase 7; a database restore alone left six originals missing in the lab |
| A periodic `borg check` and a verification restore (a failed backup unit is already an alert, [ADR 0012](decisions/0012-observability.md)) | the Borg module does neither; the restore drill |
| The **PostgreSQL 14 → 17 move**, rehearsed **on the server** in a second instance with the old database kept as the way back | sizes measured read-only on 2026-10-01 (269 MB, 7,196 assets, no pgvecto.rs); the **timed** dump, restore and search check are still to do; [ADR 0006](decisions/0006-postgresql-version-and-immich.md) |
| **Move the services to PostgreSQL** (decided by the owner): Nextcloud from MariaDB, Vaultwarden from SQLite; check that Jellyfin, Plex and Syncthing cannot (they would stay as rebuildable stores read live by Borg) | phase 4, [ADR 0004](decisions/0004-backup.md) |
| **Containers against native NixOS modules** for each service (Immich, Jellyfin, Nextcloud, Vaultwarden, and the rest): lines of configuration, update, restore | phase 4 |
| Incus (or what replaces it) on ZFS or LVM, and where the VM disks live | phase 6 ([ADR 0005](decisions/0005-storage-layout-and-filesystem.md)) |
| The pgBackRest overrides for a local repository re-checked after every module update | listed in [the exceptions register](exceptions.md); the restore drill is the test |
| **Secure Boot on NixOS** (already on in the firmware): lanzaboote with the owner's own keys, the LUKS key sealed to the signed boot chain; to try in the lab VM, then on the machine | host phase, [ADR 0005](decisions/0005-storage-layout-and-filesystem.md) |
| ~~**Docker and Incus together on one host**~~ done in [ADR 0013](decisions/0013-vms-and-containers.md); still open: **a restore of an Incus instance onto a rebuilt host** (definitions in `/var/lib/incus`, disks in the pool, both in the backup), **ZFS on the SMR disk** under random writes, the stuck VM stop after a first boot, `lxcfs`, **Jellyfin and Immich in Podman** (`/dev/dri`, the database socket), the host specification's H04 changed from Docker to Podman. Original item: **Docker and Incus together on one host** (both manage the firewall; they were not tested together) and **real VMs** instead of the lab's containers ([ADR 0010](decisions/0010-vm-service-exposure.md)); the VM manager comparison (Incus, microvm.nix, NixOS containers, libvirt) | phase 6 |
| **The VPN on real devices**: a phone and a laptop, roaming, a changed server address, the DNS for the VPN names; Tailscale as the fallback ([ADR 0009](decisions/0009-remote-access-vpn.md)) | phase 3 |
| The phase 5 rules on **real data**: the smartctl and PostgreSQL archiver rules, the heartbeat against the outside service, real mail delivery, the push to a phone ([ADR 0012](decisions/0012-observability.md)) | the real server |
| **The edge on the real machine**: the router's port forwarding (80, 443; the range 3000-3099 and the Incus API to question), the firewall on the host (v0 has none), fail2ban against the proxy's logs, HTTP/3, and the DNS records, which stay manual | phase 3 and 6, [ADR 0008](decisions/0008-edge.md) |
| The root `README.md` still describes v0 | rewrite when the first phase closes |

## Housekeeping

- The old repository `nas-scripts-history` was deleted by the owner (2026-09-30).
