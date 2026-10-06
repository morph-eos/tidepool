# Pending items

Things not done yet, so they are not lost. Each waits for the owner, for the real machine, or for a decision.

## Waiting for the owner

| Item | Why it waits | Blocks |
|---|---|---|
| **Create the private repository from `private-repo-template/`**: the machine's values (`host.nix`, `secrets.yaml`), the **age key and the Borg key exports written down** (Proton Pass and paper), the **deploy key generated on the workstation** (its private half in the sops file as `deploy-key`, its public half added to that repository as a read-only deploy key), and a first run of its `bump-public.yml` (it needs the Actions setting that lets it open pull requests) | the owner's accounts; before the deployment |
| **Set a firmware password** (and keep the boot loader's command-line editor off: with lanzaboote on NixOS it is) | the owner will do it | what makes the disk encryption protect a stolen machine ([ADR 0005](decisions/0005-storage-layout-and-filesystem.md)) |
| **The first real checks** of phase 4, at the deployment: a Seedvault backup through nginx's WebDAV, Jellyfin's transcode and Immich's machine learning on the GPU (G2), a login through Nextcloud into Immich, Jellyfin and Vaultwarden (and the SSO plugin and button for Jellyfin), the discovery address answering directly | phase 4, [ADR 0011](decisions/0011-services.md) |
| **Remove the test CNAME `_acme-challenge.test` at the DNS provider** (the two real CNAMEs are in place and served by all four nameservers) | the owner's DNS panel | tidiness |
| **Bind the CAA record to the owner's own ACME account** (`accounturi`), after the first real issuance; check whether the provider's panel accepts CAA | needs the production account's address | hardening of the DNS challenge ([ADR 0008](decisions/0008-edge.md)) |
| **Phase 5: create the Healthchecks.io account and TWO checks** (decided: free plan): one pinged by webhook every 2 minutes (period 10 min, grace 10 min), one pinged by **email** through Brevo every 6 hours (period 12 h, grace 6 h; check that the free plan accepts email pings); keep the ping URL and the check's mail address as sops secrets (`heartbeat-url`, `alertmanager-env`) ([ADR 0012](decisions/0012-observability.md)); email only through Brevo is decided | the owner's choice and account | closing phase 5 |
| **Set the SSD's share for VM disks** (a quota on the `zp` pool) when the SSDs are bought; the 2 TB disk stays ext4 and carries the `smr` directory pool ([ADR 0013](decisions/0013-vms-and-containers.md)) | the SSD purchase | the real layout |
| **New services to add** next to the v0 ones (for example a replacement for Trakt) | application layer, not infrastructure | phase 4 |


## Deferred on purpose

| Item | Why |
|---|---|
| **Memory**: the ZFS cache is capped at 3 GiB in the flake; watch the memory pressure counters in the first weeks and add RAM only if they show it ([ADR 0005](decisions/0005-storage-layout-and-filesystem.md)) | the first weeks on the real machine |
| **Disk replacement on a SMART warning** (an alert from `smartd` or similar): the 16 TB disk now holds the only copy of the media | phase 5 |
| **Self-healing of the primary disk** | deferred by the owner: done properly, with a second SSD attached as a mirror when it can be bought ([ADR 0005](decisions/0005-storage-layout-and-filesystem.md)) |
| **Scheduled ZFS snapshots** | dropped by the owner: the Borg repositories cover what they would undo; can be added later in code ([ADR 0004](decisions/0004-backup.md)) |

## Gates and checks that need the real server or a maintenance window

| Item | What it needs |
|---|---|
| G2, hardware transcoding with ffmpeg in a container | the server installed, a short maintenance window |
| G3b, the Proton Drive CLI keeping its login headless: **done in the lab** (a keyring in the container); the session's life over months is only seen on the real machine | the real machine |
| Health of the small system SSD with `smartctl` | optional: the owner judges it lightly used and easy to replace (S1 ran without root; the v0 `smartcheck` log covers the two HDDs) |

## Lab and design work still to do

| Item | Notes |
|---|---|
| **Proton Drive offsite: adopted (2026-10-06), the module is in** ([ADR 0007](decisions/0007-offsite-copy.md)). Run end to end in the lab on 2026-10-06 (first upload, a second run that skips what is identical, a trash after `borg delete` and `compact`, a download that passes `borg check --verify-data`). Left: on the real machine the login and the first upload (about 30 hours), and the session's life over months | the owner, then the real machine |
| **Fallback only, if Proton Drive fails on the real machine:** the offsite layer against a real provider (Hetzner Storage Box over SSH): real throughput, the first 200 GB upload | lab results and prices are in [ADR 0007](decisions/0007-offsite-copy.md); needs an account |
| **The full restore drill on the real machine**, after the installation: with the real data (timings at 165 GB) and **from the offsite**, whichever destination is chosen ([ADR 0007](decisions/0007-offsite-copy.md)); it passes in the lab ([ADR 0014](decisions/0014-automation-and-restore-drill.md), [the runbook](restore-drill.md)) | the real server |
| **Alerting end to end on the real host**: a real mail through Brevo (SPF and DKIM records at the DNS provider first), the heartbeat at Healthchecks.io, a deliberate failed backup to see the mail arrive, and whether to add a periodic test mail ([ADR 0012](decisions/0012-observability.md), [0015](decisions/0015-backup-verification.md)) | the real server and the owner's accounts |
| **The backup-verification timers on real data** ([ADR 0015](decisions/0015-backup-verification.md)): how long the **weekly** `borg check --verify-data` takes on 165 GB (the Borg jobs wait at most 12 hours for it, `--lock-wait 43200`, and an 8-hour run warns: raise the wait or add daily partial checks if it takes longer; [ADR 0015](decisions/0015-backup-verification.md)); the monthly restore test's time; a way to tell a good-looking but wrong Borg backup from a good one (the module's archives cannot be spot-checked); **verifying the offsite repository at the provider** | the real server |
| The **PostgreSQL 14 → 17 move**, rehearsed **on the server** in a second instance with the old database kept as the way back | sizes measured read-only on 2026-10-01 (269 MB, 7,196 assets, no pgvecto.rs); the **timed** dump, restore and search check are still to do; [ADR 0006](decisions/0006-postgresql-version-and-immich.md) |
| The pgBackRest overrides for a local repository re-checked after every module update | listed in [the exceptions register](exceptions.md); the restore drill is the test |
| **Phase 7 items for the real machine**: the **real disk layout** (UEFI, lanzaboote, LUKS with the TPM) and the **first-time provisioning** of the two large disks ([the runbook](restore-drill.md)); **wire the private repository** (domain, disks by serial, VPN peers, key) in place of `nixos/vars/example.nix`; Immich's **machine learning** and **Jellyfin with the GPU** under Podman; the **real certificates, Brevo and Healthchecks** on the integrated host; an Incus **`fast`-pool** instance lost with the SSD; whether **user ids** match across a reinstall (Borg restored by name in the lab) | the real server and the private repository |
| **Incus on the real machine:** the speed of VMs on the 2 TB SMR disk (a directory pool on ext4), the stuck VM stop after a first boot, `lxcfs`, Jellyfin and Immich in Podman (`/dev/dri`, the database socket), real VMs instead of the lab's containers ([ADR 0010](decisions/0010-vm-service-exposure.md), [ADR 0013](decisions/0013-vms-and-containers.md)) | the real machine |
| **The VPN on real devices**: a phone and a laptop, roaming, a changed server address, the DNS for the VPN names; Tailscale as the fallback ([ADR 0009](decisions/0009-remote-access-vpn.md)) | phase 3 |
| The phase 5 rules on **real data**: the smartctl and PostgreSQL archiver rules, the heartbeat against the outside service, real mail delivery, the push to a phone ([ADR 0012](decisions/0012-observability.md)) | the real server |
| **The edge on the real machine**: the router's port forwarding (80, 443; the range 3000-3099 and the Incus API to question), the firewall on the host (v0 has none), fail2ban against the proxy's logs, HTTP/3, and the DNS records, which stay manual | phase 3 and 6, [ADR 0008](decisions/0008-edge.md) |

## Updates on the real machine

| Item | Why it waits |
|---|---|
| Renovate's lock refresh and its pull requests, run end to end on the server (the `flake-check` job already runs on GitHub) | needs the machine user's token |
| Update times on the real link and disk (the lab's was 5 MiB/s) | the real server |
| Weeks of `nix-gc`, snapshot pruning (if `services.sanoid`) and Podman image pruning | time |
| A reboot that changes the kernel and ZFS together; **a kernel update on a TPM-sealed, Secure Boot disk (does it ask for the passphrase?)** | the real machine |
| **26.11 itself**, rehearsed with the restore drill when it is released (the evaluation against unstable passed) | the release (due 2026-11-30) |

## The NAS, push and the version watch ([ADR 0016](decisions/0016-updates-deploys-and-checks.md), [ADR 0017](decisions/0017-version-watch-push-and-nas.md))

Built into the flake and measured in the lab (nothing is on the real server): the **NAS**, **push through ntfy on the public side**, the **weekend version watch**, listeners bound to loopback. What each still needs at the deployment:

| Item | Why it waits |
|---|---|
| **DNS name `push.<domain>`** (the wildcard certificate covers it); the **two ntfy logins** (`phone`, `bridge`: long random passwords in the sops file, the phone's typed once into the app) | the deployment; the phone is an **Android with GrapheneOS** (F-Droid ntfy app, battery unrestricted; no relay needed) |
| **Try push on a real phone**, with Proton VPN on | the real machine |
| **The Samba user's password**: `smbpasswd -a nas` once (runbook); the database is in the Borg job | the deployment; if the owner wants it declared it becomes exception 4 |
| **The NAS on the LAN:** the **interface name** (private value), the **Time Machine partition** of the 16 TB disk mounted by the private values, a Mac that sees the share and backs up to it | the real machine and a Mac |
| **The version watch on the real machine:** the first weekend mail (a deliberately old lock proves it), whether the monthly tier (waiting on nixpkgs, majors, end of life) is the right amount of mail; **Incus is not watched** (LTS against feature releases: a line-aware source is missing) | the owner; a weekend after the deployment |
| **Nextcloud after the deployment:** start at 33 (v0's major), then 34 and 35 as separate deploys with a ZFS snapshot before each ([ADR 0017 section 9](decisions/0017-version-watch-push-and-nas.md)) | the real machine; 35 when nixpkgs has a settled 35.0.x |

## The deploy chain and the real machine ([ADR 0018](decisions/0018-deploys-by-the-server.md), [ADR 0019](decisions/0019-the-real-machine-network-and-hardware.md))

| Item | Why it waits |
|---|---|
| **Account security:** passkeys or two-factor on the owner's GitHub account, which is the root of trust of the ruleset ([ADR 0018 section 7](decisions/0018-deploys-by-the-server.md)) | the owner |
| **Encryption on the real machine** ([the runbook](encryption-runbook.md)): the firmware password, **Secure Boot into setup mode** (the firmware menu: delete the platform key, keep the revocation list), the three stages, and **the first kernel update at the console** (does the firmware keep its keys, does the firmware TPM open the disks by itself?). The lab did all of it with an emulated TPM, **including the rebuild from blank (14 checks) and the reboot in the window**; the real firmware and TPM are untried | the real machine |
| **Before the deployment, on the machine:** the **1 TB NVMe SSD** is on its way: when it arrives, fit it, read its path (`ls -l /dev/disk/by-id | grep nvme`) and put it in `tidepool.disks.tank`; **the Ethernet cable is not needed now** (the machine stays on WiFi, [ADR 0019](decisions/0019-the-real-machine-network-and-hardware.md): the `wifi` block of the private template, the key from `wpa_passphrase` in `secrets.yaml`, the router's reservation by the WiFi card's address); **copy the v0 NAS data off the 2 TB disk** (it will be LUKS) and decide where the system SSD's old Ubuntu and Windows partitions are wiped; check in the firmware that **VT-d** is on | the owner |
| **WiFi on the real card:** the card's firmware, the reconnection after a router restart, the power-saving rule, throughput, the NAS and Time Machine over the air (the lab used a virtual radio) | the real machine |
| **The move of v0's data: rehearsed in the lab** (replica of v0 at its real versions, 15 checks passed; [migration-from-v0.md](migration-from-v0.md)). Left: the real data sizes and timings, the final Jellyfin media paths, the 513 GB copy | the owner, at the cutover |
| **A machine user for Renovate:** a second free GitHub account, the Write role on the public repository (not Admin), a fine-grained token (contents and pull requests, that repository only) in the private sops file as `renovate-token`; note its expiry date. Renovate's first run follows: `renovate.json` has not run yet (the `check` workflow already runs on GitHub) | the owner's accounts |
| **Backup times with the real data**: a deploy waits for Borg of everything, Borg offsite and a pgBackRest differential; a deploy during the Sunday checks waits for them | the real machine |
| **A reboot that a new kernel needs** is signalled by the `RebootPending` alert, which fires after a day. A change of the ZFS module or the initrd with the same kernel version is not signalled by it, but the automatic reboot window covers it (NixOS compares the kernel, the initrd and the kernel modules); if the automatic reboot is switched off, watch for it by hand | nothing to build |
