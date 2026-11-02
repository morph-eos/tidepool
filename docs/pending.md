# Pending items

Things not done yet, so they are not lost. Each waits for the owner, for the real machine, or for a decision. **This is the only list of what is left to do in this repository**: the other documents point here (a to-do anywhere else is a mistake, and the CI's `docs` check says so).

## Waiting for the owner

| Item | Why it waits | Blocks |
|---|---|---|
| **The private repository is on GitHub and the machine runs from it** (since 2026-11-02; its deploy key is registered read-only): the server pulls it every ten minutes, Monday to Saturday, and a push to its `main` was seen applied (built, identical, nothing changed) within the next run; `bump-public.yml` ran on GitHub and opened its pull request on its own. Left: **the age key written down (Proton Pass and paper)**, **the LUKS header backups kept off the machine** next to the recovery passphrase, the VPN devices still to add (`tools/add-peer.sh`), the Renovate token (below) | the owner |
| **The first real checks** of phase 4, at the deployment: a Seedvault backup through nginx's WebDAV, Jellyfin's transcode and Immich's machine learning on the GPU (G2), a login through Nextcloud into Immich and Jellyfin (and the SSO plugin and button for Jellyfin; **the Vaultwarden login works, 2026-11-02**), the discovery address answering directly | phase 4, [ADR 0011](decisions/0011-services.md) |
| **Remove the test CNAME `_acme-challenge.test` at the DNS provider** (the two real CNAMEs are in place and served by all four nameservers) | the owner's DNS panel | tidiness |
| **Bind the CAA record to the owner's own ACME account** (`accounturi`): the certificates were issued (2026-11-01) and the record exists without it; the account's address is in the certificate client's state on the machine | the owner's DNS panel | hardening of the DNS challenge ([ADR 0008](decisions/0008-edge.md)) |
| **Phase 5: the Healthchecks.io account and TWO checks** (decided: free plan; **the heartbeat's pings are accepted, 2026-11-02; confirm on the Healthchecks.io page that both checks are green**): one pinged by webhook every 2 minutes (period 10 min, grace 10 min), one pinged by **email** through Brevo every 6 hours (period 12 h, grace 6 h; check that the free plan accepts email pings); keep the ping URL and the check's mail address as sops secrets (`heartbeat-url`, `alertmanager-env`) ([ADR 0012](decisions/0012-observability.md)); email only through Brevo is decided | the owner's choice and account | closing phase 5 |
| **Set the SSD's share for VM disks** (a quota on the `zp` pool) when the SSDs are bought; the 2 TB disk stays ext4 and carries the `smr` directory pool ([ADR 0013](decisions/0013-vms-and-containers.md)) | the SSD purchase | the real layout |
| **New services to add** next to the v0 ones (for example a replacement for Trakt) | application layer, not infrastructure | phase 4 |


## Deferred on purpose

| Item | Why |
|---|---|
| **Memory**: the ZFS cache is capped at 3 GiB in the flake; watch the memory pressure counters in the first weeks and add RAM only if they show it ([ADR 0005](decisions/0005-storage-layout-and-filesystem.md)) | the first weeks on the real machine |
| **Disk replacement on a SMART warning** (an alert from `smartd` or similar): the 16 TB disk now holds the only copy of the media | phase 5 |
| **Self-healing of the primary disk** | deferred by the owner: done properly, with a second SSD attached as a mirror when it can be bought ([ADR 0005](decisions/0005-storage-layout-and-filesystem.md)) |
| **Scheduled ZFS snapshots** | dropped by the owner: the Borg repositories cover what they would undo; can be added later in code ([ADR 0004](decisions/0004-backup.md)) |
| **NixOS VM tests in the CI** for what needs a booted service (Nextcloud's theming, the sign-on): the modules are monolithic and need disks and ZFS, so a test node would need the services split first; `lab/gate.sh` does it by hand for now | after the first deployment, if the manual gate is not enough |

## Gates and checks that need the real server or a maintenance window

| Item | What it needs |
|---|---|
| G2, hardware transcoding with ffmpeg in a container | the server installed, a short maintenance window |
| G3b, the Proton Drive CLI keeping its login headless: **done in the lab** (a keyring in the container); the session's life over months is only seen on the real machine | the real machine |
| Health of the small system SSD with `smartctl` | optional: the owner judges it lightly used and easy to replace (S1 ran without root; the v0 `smartcheck` log covers the two HDDs) |

## Lab and design work still to do

| Item | Notes |
|---|---|
| **Proton Drive offsite: adopted (2026-10-06), the module is in** ([ADR 0007](decisions/0007-offsite-copy.md)). Run end to end in the lab on 2026-10-06 (first upload, a second run that skips what is identical, a trash after `borg delete` and `compact`, a download that passes `borg check --verify-data`). On the real machine: the login was done and the first upload finished on 2026-11-02 (347 items, 144.75 GiB over WiFi at 110 to 155 Mbit/s, two and a half hours, not the 30 minutes first estimated). Left: **a restore from it, planned for 2026-11-03** (after the 04:50 sync has brought the copy up to date: download it to a scratch area and `borg check --verify-data`); only once that passes may the previous offsite repository on Proton Drive be deleted, and not before the old system's copies are let go (about 2026-12-02); and the session's life over months | the real machine |
| **Fallback only, if Proton Drive fails on the real machine:** the offsite layer against a real provider (Hetzner Storage Box over SSH): real throughput, the first 200 GB upload | lab results and prices are in [ADR 0007](decisions/0007-offsite-copy.md); needs an account |
| **The full restore drill on the real machine**, after the installation: with the real data (timings at 165 GB) and **from the offsite**, whichever destination is chosen ([ADR 0007](decisions/0007-offsite-copy.md)); it passes in the lab, last on 2026-11-02 on the final tree, 14 checks ([ADR 0014](decisions/0014-automation-and-restore-drill.md), [the runbook](restore-drill.md)); on the real machine the Borg archives were restored by sample (5 of 5 identical) and both repositories passed `borg check` | the real server |
| **Alerting end to end on the real host**: **a critical test alert reached the mail through Brevo and the push through ntfy, and the heartbeat's pings were accepted (2026-11-01)**; left: a deliberate failed backup to see the mail arrive, and whether to add a periodic test mail ([ADR 0012](decisions/0012-observability.md), [0015](decisions/0015-backup-verification.md)) | the real server and the owner's accounts |
| **The backup-verification timers on real data** ([ADR 0015](decisions/0015-backup-verification.md)): how long the **weekly** `borg check --verify-data` takes on 165 GB (the Borg jobs wait at most 12 hours for it, `--lock-wait 43200`, and an 8-hour run warns: raise the wait or add daily partial checks if it takes longer; [ADR 0015](decisions/0015-backup-verification.md)); the monthly restore test's time; a way to tell a good-looking but wrong Borg backup from a good one (the module's archives cannot be spot-checked); **verifying the offsite repository at the provider** | the real server |
| The **PostgreSQL 14 → 17 move**, rehearsed **on the server** in a second instance with the old database kept as the way back | sizes measured read-only on 2026-10-01 (269 MB, 7,196 assets, no pgvecto.rs); the **timed** dump, restore and search check are still to do; [ADR 0006](decisions/0006-postgresql-version-and-immich.md) |
| The pgBackRest overrides for a local repository re-checked after every module update | listed in [the exceptions register](exceptions.md); the restore drill is the test |
| **Phase 7 items for the real machine**: the **real disk layout** (UEFI, lanzaboote, LUKS with the TPM) and the **first-time provisioning** of the two large disks ([the runbook](restore-drill.md)); **wire the private repository** (domain, disks by serial, VPN peers, key) in place of `nixos/vars/example.nix`; Immich's **machine learning** and **Jellyfin with the GPU** under Podman; the **real certificates, Brevo and Healthchecks** on the integrated host; an Incus **`fast`-pool** instance lost with the SSD; whether **user ids** match across a reinstall (Borg restored by name in the lab) | the real server and the private repository |
| **Incus on the real machine:** the speed of VMs on the 2 TB SMR disk (a directory pool on ext4), the stuck VM stop after a first boot, `lxcfs`, Jellyfin and Immich in Podman (`/dev/dri`, the database socket), real VMs instead of the lab's containers ([ADR 0010](decisions/0010-vm-service-exposure.md), [ADR 0013](decisions/0013-vms-and-containers.md)) | the real machine |
| **The VPN on real devices**: a phone and a laptop, roaming, a changed server address, the DNS for the VPN names; Tailscale as the fallback ([ADR 0009](decisions/0009-remote-access-vpn.md)) | phase 3 |
| The phase 5 rules on **real data**: the smartctl and PostgreSQL archiver rules, the heartbeat against the outside service, real mail delivery, the push to a phone ([ADR 0012](decisions/0012-observability.md)) | the real server |
| **The edge on the real machine**: the router's port forwarding (80, 443; the range 3000-3099 and the Incus API to question), the firewall on the host (v0 has none), fail2ban against the proxy's logs, HTTP/3, and the DNS records, which stay manual | phase 3 and 6, [ADR 0008](decisions/0008-edge.md) |

## Before the first deployment, on this repository's side


| Item | Why it waits |
|---|---|
| **The admin page on the real machine** ([ADR 0021](decisions/0021-admin-page.md), a trial, on by default): the DNS record `admin` to 10.100.0.1; look at it for a few weeks and decide to keep it, replace it or drop it (and whether Grafana joins it); Nextcloud's status dot may need the router to loop back | the owner's DNS; the real machine |

## Updates on the real machine

| Item | Why it waits |
|---|---|
| Renovate's lock refresh and its pull requests, run end to end on the server (the `flake-check` job already runs on GitHub) | needs the machine user's token |
| Update times on the real link and disk (the lab's was 5 MiB/s) | the real server |
| Weeks of `nix-gc`, snapshot pruning (if `services.sanoid`) and Podman image pruning | time |
| A reboot that changes the kernel and ZFS together | the real machine (**a kernel update on the TPM-sealed, Secure Boot disk was rehearsed at the console on 2026-11-02, 6.18 to 6.12: no passphrase, the same PCR 7**) |
| **26.11 itself**, rehearsed with the restore drill when it is released (the evaluation against unstable passed) | the release (due 2026-11-30) |

## The NAS, push and the version watch ([ADR 0016](decisions/0016-updates-deploys-and-checks.md), [ADR 0017](decisions/0017-version-watch-push-and-nas.md))

Built into the flake and measured in the lab (nothing is on the real server): the **NAS**, **push through ntfy on the public side**, the **weekend version watch**, listeners bound to loopback. What each still needs at the deployment:

| Item | Why it waits |
|---|---|
| **DNS name `push.<domain>`** (the wildcard certificate covers it); the **two ntfy logins** (`phone`, `bridge`: long random passwords in the sops file, the phone's typed once into the app) | the deployment; the phone is an **Android with GrapheneOS** (F-Droid ntfy app, battery unrestricted; no relay needed) |
| **Try push on a real phone**, with Proton VPN on | the real machine |
| **The Samba user's password**: `smbpasswd -a nas` once (done 2026-11-02); the database is in the Borg job. **v0 shared three trees** (the main one, the media one, Time Machine) **for the admin user**; here there is one share for a dedicated Samba user, so a device that saved the old login must be given the new one. To decide: publish the media tree as a second share, and whether the old login name becomes an alias (`username map`) | the owner; if the password or the alias is declared it becomes a new entry in the exceptions register |
| **The NAS on the LAN:** the interface name is the WiFi one (the machine stays on WiFi, [ADR 0019](decisions/0019-the-real-machine-network-and-hardware.md)); the Time Machine partition is made ext4 **after the move has settled**, not at the cutover (Linux cannot write a journaled HFS+; the host declares neither the share nor its mount until then); a Mac that sees the share and backs up to it | the real machine and a Mac |
| **The version watch on the real machine:** the first weekend mail (a deliberately old lock proves it), whether the monthly tier (waiting on nixpkgs, majors, end of life) is the right amount of mail; **Incus is not watched** (LTS against feature releases: a line-aware source is missing) | the owner; a weekend after the deployment |
| **Nextcloud after the deployment:** start at 33 (v0's major), then 34 and 35 as separate deploys with a ZFS snapshot before each ([ADR 0017 section 9](decisions/0017-version-watch-push-and-nas.md)) | the real machine; 35 when nixpkgs has a settled 35.0.x |

## The deploy chain and the real machine ([ADR 0018](decisions/0018-deploys-by-the-server.md), [ADR 0019](decisions/0019-the-real-machine-network-and-hardware.md))

| Item | Why it waits |
|---|---|
| **The names of the Incus instances** ([ADR 0010](decisions/0010-vm-service-exposure.md), [names](names.md)): the DNS records exist; at the deployment the zone's certificate is ordered (the secret `acme-dns-credentials` needs both registrations' usernames and passwords), the CAA record is checked again after it, an instance answers over the VPN and not without it, `ssh <instance>.incus` works from a device that sends the `.incus` names to the server (not tried on a real client) | the real machine and the owner's accounts |
| **The brand and the single sign-on on the real machine** ([ADR 0020](decisions/0020-brand-identity.md)): the social preview image (`docs/brand/social-preview.png`) uploaded in the repository's settings (a manual step); the first login through Nextcloud with real accounts (each needs an email address) and what happens to Immich users that already exist with the same email (not tried); the identity itself, which is a placeholder until the owner chooses | the owner; the real machine |
| **WiFi on the real card** (the permanent link, [ADR 0019](decisions/0019-the-real-machine-network-and-hardware.md)): the card works (the firmware, the power-saving rule, 110 to 155 Mbit/s of upload during the Proton Drive copy). Left: **the reconnection after a router restart** (never tried), the NAS from real clients over the air, and Time Machine when it is switched on | the real machine |
| **A machine user for Renovate:** a second free GitHub account, the Write role on the public repository (not Admin), a fine-grained token (contents and pull requests, that repository only) in the private sops file as `renovate-token`; note its expiry date. Renovate's first run follows: `renovate.json` has not run yet (the `check` workflow already runs on GitHub) | the owner's accounts |
| **Backup times with the real data**: a deploy waits for Borg of everything, Borg offsite and a pgBackRest differential; a deploy during the Sunday checks waits for them | the real machine |
| **A reboot that a new kernel needs** is signalled by the `RebootPending` alert, which fires after a day. A change of the ZFS module or the initrd with the same kernel version is not signalled by it, but the automatic reboot window covers it (NixOS compares the kernel, the initrd and the kernel modules); if the automatic reboot is switched off, watch for it by hand | nothing to build |
