# Pending items

Things deliberately postponed, so they are not lost. Each has an owner decision or a gate behind it. Updated 2026-10-03, after the phase 8 follow-up (phase 7 before that) (the integrated flake and the restore drill).

## Waiting for the owner

| Item | Why it waits | Blocks |
|---|---|---|
| **Phase 8: decide** the structure (a private flake importing the public one), how updates are found (Renovate and `flake.lock`: weekly Action or by hand), the cadence, the rollback point (a line in the runbook or `services.sanoid`, which would reverse the "no scheduled snapshots" decision), 26.05 or 26.11 for the first deployment, whether a human starts every deploy ([ADR 0016](decisions/0016-updates-deploys-and-checks.md)) | the owner's choice | an unattended, maintained system |
| **Buy one SSD of about 500 GB** (chosen: [ADR 0005](decisions/0005-storage-layout-and-filesystem.md)); a second one later, as a mirror | the owner's money | the real layout |
| **Create the private repository** for the non-secret variables, and **write the age key and the Borg key exports down** (Proton Pass and paper) | the owner's accounts | closing phase 1 |
| (Only if Proton Drive fails its test) **open the Hetzner Storage Box account** and set its snapshot plan | a subscription and the console | the offsite copy in that case ([ADR 0007](decisions/0007-offsite-copy.md)) |
| **Set a firmware password** (and keep the boot loader's command-line editor off: with lanzaboote on NixOS it is) | the owner will do it | what makes the disk encryption protect a stolen machine ([ADR 0005](decisions/0005-storage-layout-and-filesystem.md)) |
| **The first real checks** of phase 4, at the deployment: a Seedvault backup through nginx's WebDAV, Jellyfin's transcode and Immich's machine learning on the GPU (G2), a login through Nextcloud into Immich, Jellyfin and Vaultwarden (and the SSO plugin and button for Jellyfin), the discovery address answering directly | phase 4, [ADR 0011](decisions/0011-services.md) |
| **Services to carry over to v1** ([ADR 0008](decisions/0008-edge.md)): **Plex and icloudpd are dropped**; Syncthing stays with its sync port public and its GUI VPN-only; Jellyfin, Immich, Nextcloud, Vaultwarden and WebDAV (through nginx) move over; new services come after | phase 4 |
| **Remove the test CNAME `_acme-challenge.test` at the DNS provider** (the two real CNAMEs are in place and served by all four nameservers) | the owner's DNS panel | tidiness |
| **Bind the CAA record to the owner's own ACME account** (`accounturi`), after the first real issuance; check whether the provider's panel accepts CAA | needs the production account's address | hardening of the DNS challenge ([ADR 0008](decisions/0008-edge.md)) |
| **Phase 5: create the Healthchecks.io account and TWO checks** (decided: free plan): one pinged by webhook every 2 minutes (period 10 min, grace 10 min), one pinged by **email** through Brevo every 6 hours (period 12 h, grace 6 h; check that the free plan accepts email pings); keep the ping URL and the check's mail address as sops secrets (`heartbeat-url`, `alertmanager-env`) ([ADR 0012](decisions/0012-observability.md)); email only through Brevo is decided | the owner's choice and account | closing phase 5 |
| **Set the SSD's share for VM disks** (a quota on the `zp` pool) when the SSDs are bought; the 2 TB disk stays ext4 and carries the `smr` directory pool ([ADR 0013](decisions/0013-vms-and-containers.md)) | the SSD purchase | the real layout |
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
| ~~The full restore drill~~ **passed in the lab** ([ADR 0014](decisions/0014-automation-and-restore-drill.md), [the runbook](restore-drill.md)); **to repeat on the real machine** after installation, with real data (timings at 165 GB), and **from the offsite** (a Hetzner snapshot's `/.zfs/snapshot` path, Proton Drive) | the real server |
| **Alerting end to end on the real host**: a real mail through Brevo (SPF and DKIM records at the DNS provider first), the heartbeat at Healthchecks.io, a deliberate failed backup to see the mail arrive, and whether to add a periodic test mail ([ADR 0012](decisions/0012-observability.md), [0015](decisions/0015-backup-verification.md)) | the real server and the owner's accounts |
| **The backup-verification timers on real data** ([ADR 0015](decisions/0015-backup-verification.md)): how long the **weekly** `borg check --verify-data` takes on 165 GB (the Borg jobs wait at most 12 hours for it, `--lock-wait 43200`, and an 8-hour run warns: raise the wait or add daily partial checks if it takes longer; [ADR 0015](decisions/0015-backup-verification.md)); the monthly restore test's time; a way to tell a good-looking but wrong Borg backup from a good one (the module's archives cannot be spot-checked); **verifying the offsite repository at the provider** | the real server |
| The **PostgreSQL 14 → 17 move**, rehearsed **on the server** in a second instance with the old database kept as the way back | sizes measured read-only on 2026-10-01 (269 MB, 7,196 assets, no pgvecto.rs); the **timed** dump, restore and search check are still to do; [ADR 0006](decisions/0006-postgresql-version-and-immich.md) |
| **Move the services to PostgreSQL** (decided by the owner): Nextcloud from MariaDB, Vaultwarden from SQLite; check that Jellyfin, Plex and Syncthing cannot (they would stay as rebuildable stores read live by Borg) | phase 4, [ADR 0004](decisions/0004-backup.md) |
| **Containers against native NixOS modules** for each service (Immich, Jellyfin, Nextcloud, Vaultwarden, and the rest): lines of configuration, update, restore | phase 4 |
| Incus (or what replaces it) on ZFS or LVM, and where the VM disks live | phase 6 ([ADR 0005](decisions/0005-storage-layout-and-filesystem.md)) |
| The pgBackRest overrides for a local repository re-checked after every module update | listed in [the exceptions register](exceptions.md); the restore drill is the test |
| **Secure Boot on NixOS** (already on in the firmware): lanzaboote with the owner's own keys, the LUKS key sealed to the signed boot chain; to try in the lab VM, then on the machine | host phase, [ADR 0005](decisions/0005-storage-layout-and-filesystem.md) |
| **Phase 7 items for the real machine**: the **real disk layout** (UEFI, lanzaboote, LUKS with the TPM) and the **first-time provisioning** of the two large disks ([the runbook](restore-drill.md)); **wire the private repository** (domain, disks by serial, VPN peers, key) in place of `nixos/vars/example.nix`; Immich's **machine learning** and **Jellyfin with the GPU** under Podman; the **real certificates, Brevo and Healthchecks** on the integrated host; an Incus **`fast`-pool** instance lost with the SSD; whether **user ids** match across a reinstall (Borg restored by name in the lab) | the real server and the private repository |
| **Where the checks run on their own** (a git hook, GitHub Actions or by hand) and **how often the full drill repeats** ([ADR 0014](decisions/0014-automation-and-restore-drill.md)) | the owner's choice |
| ~~**Docker and Incus together on one host**~~ done in [ADR 0013](decisions/0013-vms-and-containers.md); still open: ~~a restore of an Incus instance onto a rebuilt host~~ done: Incus's state is on the 2 TB disk ([ADR 0014](decisions/0014-automation-and-restore-drill.md)); **the speed of VMs on the 2 TB SMR disk** (a directory pool on ext4), the stuck VM stop after a first boot, `lxcfs`, **Jellyfin and Immich in Podman** (`/dev/dri`, the database socket), the host specification's H04 changed from Docker to Podman. Original item: **Docker and Incus together on one host** (both manage the firewall; they were not tested together) and **real VMs** instead of the lab's containers ([ADR 0010](decisions/0010-vm-service-exposure.md)); the VM manager comparison (Incus, microvm.nix, NixOS containers, libvirt) | phase 6 |
| **The VPN on real devices**: a phone and a laptop, roaming, a changed server address, the DNS for the VPN names; Tailscale as the fallback ([ADR 0009](decisions/0009-remote-access-vpn.md)) | phase 3 |
| The phase 5 rules on **real data**: the smartctl and PostgreSQL archiver rules, the heartbeat against the outside service, real mail delivery, the push to a phone ([ADR 0012](decisions/0012-observability.md)) | the real server |
| **The edge on the real machine**: the router's port forwarding (80, 443; the range 3000-3099 and the Incus API to question), the firewall on the host (v0 has none), fail2ban against the proxy's logs, HTTP/3, and the DNS records, which stay manual | phase 3 and 6, [ADR 0008](decisions/0008-edge.md) |

## Phase 8 items that only the real setup can test

| Item | Why it waits |
|---|---|
| GitHub Actions (`nix flake check`), Renovate's app or its lock refresh, the `update-flake-lock` Action, run end to end; the repository's visibility and plan | needs a GitHub run and the owner's accounts |
| Update times on the real link and disk (the lab's was 5 MiB/s) | the real server |
| Weeks of `nix-gc`, snapshot pruning (if `services.sanoid`) and Podman image pruning | time |
| A reboot that changes the kernel and ZFS together; **a kernel update on a TPM-sealed, Secure Boot disk (does it ask for the passphrase?)** | the real machine |
| **26.11 itself**, rehearsed with the restore drill when it is released (the evaluation against unstable passed) | the release (due 2026-11-30) |
| comin's testing branch; colmena; a `nixosTest` of the drill; `vulnix` with a whitelist | not needed for the proposal |

## From the 2026-10-03 follow-up ([ADR 0016](decisions/0016-updates-deploys-and-checks.md), [ADR 0017](decisions/0017-version-watch-push-and-nas.md))

Built into the flake and measured in the lab (nothing is on the real server): the **NAS**, **push through ntfy on the public side**, the **weekend version watch**, listeners bound to loopback. What each still needs at the deployment:

| Item | Why it waits |
|---|---|
| **DNS name `ntfy.<domain>`** (the wildcard certificate covers it); the **two ntfy logins** (`phone`, `bridge`: long random passwords in the sops file, the phone's typed once into the app) | the deployment; the phone is an **Android with GrapheneOS** (F-Droid ntfy app, battery unrestricted; no relay needed) |
| **Try push on a real phone**, with Proton VPN on | the real machine |
| **The Samba user's password**: `smbpasswd -a nas` once (runbook); the database is in the Borg job | the deployment; if the owner wants it declared it becomes exception 3 |
| **The NAS on the LAN:** the **interface name** (private value), the **Time Machine partition** of the 16 TB disk mounted by the private values, a Mac that sees the share and backs up to it | the real machine and a Mac |
| **The 2 TB disk's capacity budget** (offsite repository, Incus pool and state, the NAS share) is not written down | the real sizes |
| **The version watch on the real machine:** the first weekend mail (a deliberately old lock proves it), whether the monthly tier (waiting on nixpkgs, majors, end of life) is the right amount of mail; **Incus is not watched** (LTS against feature releases: a line-aware source is missing) | the owner; a weekend after the deployment |
| **Nextcloud after the deployment:** start at 33 (v0's major), then 34 and 35 as separate deploys with a ZFS snapshot before each ([ADR 0017 section 9](decisions/0017-version-watch-push-and-nas.md)) | the real machine; 35 when nixpkgs has a settled 35.0.x |
| **PostgreSQL 18 for the first deployment?** The dump restore (ADR 0006) and the restore drill (ADR 0014) must be repeated on 18 first | the owner's decision 7 in ADR 0017 |
| **Publishing the repository:** a **fresh public repository** with only the intended branches and tags, a repeat of the secret scan on what is pushed, and the **old scripts' security problems** (`main`, `v0`) fixed or left out; GitHub may keep rewritten commits reachable by hash | the owner, after the transfer to the server |
| **The server's credentials for the repositories:** none for the public one; the private one by copy or a read-only deploy key; **Renovate on the server (`services.renovate`) or on GitHub**; a **runner on the server** or not | the owner's answers to question 10 of ADR 0016 |
| **Syncthing's local-discovery port (UDP 21027) is open on every interface** | tidy up when the services module is revisited; not reachable from the Internet (the router does not forward it) |

## From the 2026-10-03 deploy work ([ADR 0018](decisions/0018-deploys-by-the-server.md))

| Item | Why it waits |
|---|---|
| **Decided (2026-10-03):** autoUpgrade, 10 minutes, every protection on the public `main`, **two merges**, **the reboot in a 06:00 to 07:00 window**, **Renovate on the server**. Still to do: see the next rows |
| **Create the private repository**, generate the **deploy key on the workstation**, put its private half in the private sops file (`deploy-key`), add its public half to that repository as a **read-only deploy key**, and write the private flake (`flake.nix` importing the public one, `host.nix`, `secrets.yaml`) | the owner's accounts; before the deployment |
| **Make the public repository public** (a fresh one, [ADR 0017 section 6](decisions/0017-version-watch-push-and-nas.md)), then **import `.github/rulesets/main.json`** (`gh api -X POST repos/OWNER/REPO/rulesets --input .github/rulesets/main.json`; check the admin role id and the field names), tick the settings checklist of [ADR 0018 section 7](decisions/0018-deploys-by-the-server.md), install **Renovate's app** on the public repository only | the owner, after the transfer |
| **Create the private repository from `private-repo-template/`** and try its `bump-public.yml` (it needs the Actions setting that lets it open pull requests) | the owner; the workflow has not run on GitHub |
| **Encryption on the real machine** ([the runbook](encryption-runbook.md)): the firmware password, **Secure Boot into setup mode** (the firmware menu: delete the platform key, keep the revocation list), the three stages, and **the first kernel update at the console** (does the firmware keep its keys, does the firmware TPM open the disks by itself?). The lab did all of it with an emulated TPM, **including the rebuild from blank (14 checks) and the reboot in the window**; the real firmware and TPM are untried | the real machine |
| **Before the deployment, on the machine:** the **1 TB NVMe SSD** is on its way: when it arrives, fit it, read its path (`ls -l /dev/disk/by-id | grep nvme`) and put it in `tidepool.disks.tank`; **the Ethernet cable is not needed now** (the machine stays on WiFi, [ADR 0019](decisions/0019-the-real-machine-network-and-hardware.md): the `wifi` block of the private template, the key from `wpa_passphrase` in `secrets.yaml`, the router's reservation by the WiFi card's address); **copy the v0 NAS data off the 2 TB disk** (it will be LUKS) and decide where the system SSD's old Ubuntu and Windows partitions are wiped; check in the firmware that **VT-d** is on | the owner |
| **WiFi on the real card:** the card's firmware, the reconnection after a router restart, the power-saving rule, throughput, the NAS and Time Machine over the air (the lab used a virtual radio) | the real machine |
| **The move of v0's data: rehearsed in the lab** (replica of v0 at its real versions, 15 checks passed; [migration-from-v0.md](migration-from-v0.md)). Left: the real data sizes and timings, the final Jellyfin media paths, the 513 GB copy | the owner, at the cutover |
| **A machine user for Renovate:** a second free GitHub account, the Write role on the public repository (not Admin), a fine-grained token (contents and pull requests, that repository only) in the private sops file as `renovate-token`; note its expiry date | the owner's accounts |
| **Run the written GitHub files for the first time** (`.github/workflows/check.yml`, `renovate.json`): neither has run on GitHub | the public repository |
| **Backup times with the real data**: a deploy waits for Borg of everything, Borg offsite and a pgBackRest differential; a deploy during the Sunday checks waits for them | the real machine |
| **"A reboot is pending"** (a new kernel or ZFS) is not signalled anywhere | a small alert if wanted |
| **comin with the backups before the switch** and its idle cost; **a build that fails halfway** (only evaluation errors and backup failures were injected) | only if comin is considered again |

## Housekeeping

- The old repository `nas-scripts-history` was deleted by the owner (2026-09-30).
