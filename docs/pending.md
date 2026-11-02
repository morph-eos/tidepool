# Pending items

Things not done yet, so they are not lost. Each waits for something I have to do, for a deployment on real hardware, or for a decision. **This is the only list of what is left to do in this repository**: the other documents point here (a to-do anywhere else is a mistake, and the CI's `docs` check says so).

## Waiting for accounts, DNS and devices

| Item | Why it waits | Blocks |
|---|---|---|
| **The private repository on GitHub**: its read-only deploy key, the VPN devices (`tools/add-peer.sh`), and the Renovate token (below) | accounts and devices | the deploy chain |
| **The first real checks** of phase 4: a Seedvault backup through nginx's WebDAV, Jellyfin's transcode and Immich's machine learning on the GPU (G2), a login through Nextcloud into Immich, Jellyfin and Vaultwarden (and the SSO plugin and button for Jellyfin), the discovery address answering directly | real hardware | phase 4, [ADR 0011](decisions/0011-services.md) |
| **Bind the CAA record to the ACME account** (`accounturi`) after the first issuance; the account's address is in the certificate client's state | the DNS panel | hardening of the DNS challenge ([ADR 0008](decisions/0008-edge.md)) |
| **Phase 5: the Healthchecks.io account and two checks** (free plan): one pinged by webhook every 2 minutes (period 10 min, grace 10 min), one pinged by email through the relay every 6 hours (period 12 h, grace 6 h; check that the free plan accepts email pings); the ping URL and the check's address are sops secrets (`heartbeat-url`, `alertmanager-env`) ([ADR 0012](decisions/0012-observability.md)) | an account | closing phase 5 |
| **Set the SSD's share for VM disks** (a quota on the `zp` pool); the mid-size disk stays ext4 and carries the `smr` directory pool ([ADR 0013](decisions/0013-vms-and-containers.md)) | the real layout | the real layout |
| **New services to add** next to the migrated ones | application layer, not infrastructure | phase 4 |

## Deferred on purpose

| Item | Why |
|---|---|
| **Memory**: the ZFS cache is capped at 3 GiB in the flake; watch the memory pressure counters in the first weeks and add RAM only if they show it ([ADR 0005](decisions/0005-storage-layout-and-filesystem.md)) | the first weeks on real hardware |
| **Disk replacement on a SMART warning** (an alert from `smartd` or similar): the large disk holds the only copy of the media | phase 5 |
| **Self-healing of the primary disk** | deferred: done properly, with a second SSD attached as a mirror ([ADR 0005](decisions/0005-storage-layout-and-filesystem.md)) |
| **Scheduled ZFS snapshots** | dropped: the Borg repositories cover what they would undo; can be added later in code ([ADR 0004](decisions/0004-backup.md)) |
| **NixOS VM tests in the CI** for what needs a booted service (Nextcloud's theming, the sign-on): the modules are monolithic and need disks and ZFS, so a test node would need the services split first; `lab/gate.sh` does it by hand for now | after the first deployment, if the manual gate is not enough |

## Gates and checks that need real hardware or a maintenance window

| Item | What it needs |
|---|---|
| G2, hardware transcoding with ffmpeg in a container | the server installed, a short maintenance window |
| G3b, the Proton Drive CLI keeping its login headless: done in the lab (a keyring in the container); the session's life over months is only seen on real hardware | real hardware |
| Health of the small system SSD with `smartctl` | optional: it is lightly used and easy to replace |

## Lab and design work still to do

| Item | Notes |
|---|---|
| **Proton Drive offsite: adopted, the module is in** ([ADR 0007](decisions/0007-offsite-copy.md)). Run end to end in the lab (first upload, a second run that skips what is identical, a trash after `borg delete` and `compact`, a download that passes `borg check --verify-data`). Left on real hardware: a restore from the cloud copy, and the session's life over months | real hardware |
| **Fallback only, if Proton Drive fails:** the offsite layer against a real provider (a Hetzner Storage Box over SSH): real throughput, the first large upload | lab results and prices are in [ADR 0007](decisions/0007-offsite-copy.md); needs an account |
| **The full restore drill on real hardware**, with real data and from the offsite copy ([ADR 0007](decisions/0007-offsite-copy.md)); it passes in the lab on the final tree, 14 checks ([ADR 0014](decisions/0014-automation-and-restore-drill.md), [the runbook](restore-drill.md)) | real hardware |
| **Alerting end to end on a real host**: a critical test alert through the mail relay and the push, the heartbeat; left: a deliberately failed backup to see the mail arrive, and whether to add a periodic test mail ([ADR 0012](decisions/0012-observability.md), [0015](decisions/0015-backup-verification.md)) | real hardware and the accounts |
| **The backup-verification timers on real data** ([ADR 0015](decisions/0015-backup-verification.md)): how long the weekly `borg check --verify-data` takes (the Borg jobs wait at most 12 hours for it, `--lock-wait 43200`, and an 8-hour run warns: raise the wait or add daily partial checks if it takes longer); the monthly restore test's time; a way to tell a good-looking but wrong Borg backup from a good one; verifying the offsite repository at the provider | real hardware |
| **The PostgreSQL 14 → 17 move**, rehearsed on the server in a second instance with the old database kept as the way back: the timed dump, restore and search check are still to do ([ADR 0006](decisions/0006-postgresql-version-and-immich.md)) | real hardware |
| The pgBackRest overrides for a local repository re-checked after every module update | listed in [the exceptions register](exceptions.md); the restore drill is the test |
| **Phase 7 items for real hardware**: the real disk layout (UEFI, lanzaboote, LUKS with the TPM) and the first-time provisioning of the large disks ([the runbook](restore-drill.md)); wiring the private repository (domain, disks by serial, VPN peers, key) in place of `nixos/vars/example.nix`; Immich's machine learning and Jellyfin with the GPU under Podman; the real certificates, mail relay and Healthchecks on the integrated host; an Incus `fast`-pool instance lost with the SSD; whether user ids match across a reinstall (Borg restored by name in the lab) | real hardware and the private repository |
| **Incus on real hardware:** the speed of VMs on the SMR disk (a directory pool on ext4), the stuck VM stop after a first boot, `lxcfs`, Jellyfin and Immich in Podman (`/dev/dri`, the database socket), real VMs instead of the lab's containers ([ADR 0010](decisions/0010-vm-service-exposure.md), [ADR 0013](decisions/0013-vms-and-containers.md)) | real hardware |
| **The VPN on real devices**: a phone and a laptop, roaming, a changed server address, the DNS for the VPN names; Tailscale as the fallback ([ADR 0009](decisions/0009-remote-access-vpn.md)) | phase 3 |
| The phase 5 rules on real data: the smartctl and PostgreSQL archiver rules, the heartbeat against the outside service, real mail delivery, the push to a phone ([ADR 0012](decisions/0012-observability.md)) | real hardware |
| **The edge on real hardware**: the router's port forwarding (80, 443), the firewall on the host, fail2ban against the proxy's logs, HTTP/3, and the DNS records, which stay manual | phase 3 and 6, [ADR 0008](decisions/0008-edge.md) |

## Before the first deployment, on this repository's side

| Item | Why it waits |
|---|---|
| **The admin page on real hardware** ([ADR 0021](decisions/0021-admin-page.md), a trial, on by default): the DNS record `admin`; look at it for a few weeks and decide to keep it, replace it or drop it (and whether Grafana joins it); Nextcloud's status dot may need the router to loop back | the DNS; real hardware |

## Updates on real hardware

| Item | Why it waits |
|---|---|
| Renovate's lock refresh and its pull requests, run end to end on the server (the `flake-check` job already runs on GitHub) | needs the machine user's token |
| Update times on the real link and disk (the lab's was 5 MiB/s) | real hardware |
| Weeks of `nix-gc`, snapshot pruning (if `services.sanoid`) and Podman image pruning | time |
| A reboot that changes the kernel and ZFS together | real hardware |
| **26.11 itself**, rehearsed with the restore drill when it is released (the evaluation against unstable passed) | the release (due 2026-11-30) |

## The NAS, push and the version watch ([ADR 0016](decisions/0016-updates-deploys-and-checks.md), [ADR 0017](decisions/0017-version-watch-push-and-nas.md))

Built into the flake and measured in the lab: the NAS, push through ntfy on the public side, the weekend version watch, listeners bound to loopback. What each still needs at the deployment:

| Item | Why it waits |
|---|---|
| **DNS name `push.<domain>`** (the wildcard certificate covers it); the two ntfy logins (`phone`, `bridge`: long random passwords in the sops file, the phone's typed once into the app) | the deployment; on an Android without Google services the ntfy app keeps its own connection and no relay is needed |
| **Try push on a real phone** | real hardware |
| **The Samba user's password**: `smbpasswd -a <user>` once; the database is in the Borg job. Whether to publish the media tree as a second share | a decision; if the password or an alias (`username map`) is declared it becomes a new entry in the exceptions register |
| **The NAS on the LAN:** the interface name is the WiFi one ([ADR 0019](decisions/0019-the-real-machine-network-and-hardware.md)); the Time Machine partition is made ext4 after the move has settled, not at the cutover (Linux cannot write a journaled HFS+; the host declares neither the share nor its mount until then); a Mac that sees the share and backs up to it | real hardware and a Mac |
| **The version watch on real hardware:** the first weekend mail (a deliberately old lock proves it), whether the monthly tier (waiting on nixpkgs, majors, end of life) is the right amount of mail; Incus is not watched (LTS against feature releases: a line-aware source is missing) | a weekend after the deployment |
| **Nextcloud after the deployment:** start at 33, then 34 and 35 as separate deploys with a ZFS snapshot before each ([ADR 0017 section 9](decisions/0017-version-watch-push-and-nas.md)) | real hardware; 35 when nixpkgs has a settled 35.0.x |

## The deploy chain and real hardware ([ADR 0018](decisions/0018-deploys-by-the-server.md), [ADR 0019](decisions/0019-the-real-machine-network-and-hardware.md))

| Item | Why it waits |
|---|---|
| **The names of the Incus instances** ([ADR 0010](decisions/0010-vm-service-exposure.md), [names](names.md)): the zone's certificate is ordered (the secret `acme-dns-credentials` needs both registrations' usernames and passwords), the CAA record is checked again after it, an instance answers over the VPN and not without it, `ssh <instance>.incus` works from a device that sends the `.incus` names to the server (not tried on a real client) | real hardware and the accounts |
| **The brand and the single sign-on on real hardware** ([ADR 0020](decisions/0020-brand-identity.md)): the social preview image (`docs/brand/social-preview.png`) uploaded in the repository's settings (a manual step); the first login through Nextcloud with real accounts (each needs an email address) and what happens to Immich users that already exist with the same email (not tried); the identity itself, which is a placeholder | a decision; real hardware |
| **WiFi on a real card** ([ADR 0019](decisions/0019-the-real-machine-network-and-hardware.md)): the reconnection after a router restart, the NAS from real clients over the air, the radio's power saving read on the live card, and Time Machine when it is switched on | real hardware |
| **A machine user for Renovate:** a second free GitHub account, the Write role on the public repository (not Admin), a fine-grained token (contents and pull requests, that repository only) in the private sops file as `renovate-token`; note its expiry date. Renovate's first run follows: `renovate.json` has not run yet (the `check` workflow already runs on GitHub) | an account |
| **Backup times with real data**: a deploy waits for Borg of everything, Borg offsite and a pgBackRest differential; a deploy during the Sunday checks waits for them | real hardware |
| **A reboot that a new kernel needs** is signalled by the `RebootPending` alert, which fires after a day. A change of the ZFS module or the initrd with the same kernel version is not signalled by it, but the automatic reboot window covers it (NixOS compares the kernel, the initrd and the kernel modules); if the automatic reboot is switched off, watch for it by hand | nothing to build |
