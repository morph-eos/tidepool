# 0016. Updates, deploys, and where the checks run

- **Status:** proposed (2026-10-03): measured in the lab; the policy choices are the owner's (listed at the end)
- **Date:** 2026-10-03
- **Phase:** 8, Updates and automation

## Context

Phases 0-7 decided and proved how the server is built, backed up, watched and restored. **Nothing decided how it stays up to date**, how a new version reaches the machine, what happens when a deploy goes wrong, or where the quick checks of [ADR 0014](0014-automation-and-restore-drill.md) run on their own. The owner asked for a study with lab tests before choosing.

Three facts frame it:

- **Support has a date.** NixOS 26.05, the release the flake is pinned to, gets security updates until **2026-12-31**; 26.11 is due at the **end of November 2026** (the release milestone's due date is 2026-11-30). Today is 2026-10-03, and the real deployment has not happened: the first real machine would run a release that is about three months from its end, or the next one from its first week.
- **The exposed services publish security advisories all the time** (below).
- **The repository is private** (`gh repo view`: private), and the owner's private values (domain, disks, VPN peers) are not yet wired ([ADR 0003](0003-secrets.md)); the way they reach the host decides how updates are built and tested.

## Requirements

- **Must:** no update reaches the real machine unseen **and** irreversible: any update that can change a service's data has a **way back that works** (measured, not assumed); a failed update is noticed by the channel of [ADR 0012](0012-observability.md); the private values never enter the public repository ([ADR 0003](0003-secrets.md)); what is deployed is **what was tested** (the same lock, the same revision); no script of ours in the path (P1), exceptions only in [the register](../exceptions.md).
- **Should:** exposed services updated within days of a serious advisory; routine updates cheap in the owner's time (a few minutes a week); the system disk (119 GB) does not fill; the quick checks run without the owner remembering.
- **Won't:** unattended major-version changes of anything with state; a paid service; a build on the server that takes hours.

## What there is to update, and how often it matters

| Component | Where its version is set | What an update does | Can NixOS roll it back? |
|---|---|---|---|
| The system (kernel, systemd, glibc, nginx, OpenSSH, Podman, ZFS, Borg, pgBackRest, Syncthing, Vaultwarden) | `flake.lock`, input `nixpkgs` (branch `nixos-26.05`) | a new generation; services restart; **a new kernel needs a reboot** | **yes**, the previous generation is still installed |
| `sops-nix`, `disko` | `flake.lock` | rarely matters at runtime | yes |
| PostgreSQL 17 | nixpkgs (minor versions) | a restart | a minor version: yes (same data format). **A major version is a manual dump and restore** ([ADR 0006](0006-postgresql-version-and-immich.md)) |
| Nextcloud 33 | nixpkgs (`nextcloud33`, patch releases) | `occ upgrade` on start | **no**: measured below, it refuses to go back |
| Immich, Jellyfin, Valkey | the digest in `services.nix` | the container is replaced; Immich migrates its schema | the image can be put back, **the data may not follow** |
| Incus instances | per instance | not part of the flake | n/a |

**Releases and advisories** (the GitHub APIs, 2026-10-03; the counts are what upstream published, not what affects this server):

| | Releases, last 90 days | Last 365 days | Security advisories, last 365 days |
|---|---|---|---|
| Immich | 7 | 33 | 12 (1 critical, 3 high) |
| Jellyfin | 2 | 14 | 15 (2 critical, 4 high) |
| Nextcloud server | 11 | 35 | 51 (7 high) |
| Vaultwarden | 4 | 14 | 15 (7 high) |
| Syncthing | 3 | 11 | 0 |
| Borg | 1 | 4 | 1 (low) |
| pgBackRest | 3 | 5 | not listed |
| nixpkgs `release-26.05` | | | 1,948 commits in the last 30 days |

The four services exposed to the Internet ([ADR 0008](0008-edge.md)) published **93 advisories in a year, 24 of them high or critical: two a month**. A monthly cadence can leave a serious one open for four weeks; a weekly look shortens that to one.

## Questions

1. How do new versions **find us**? 2. How are they **tested** before they touch the server? 3. How are they **deployed**, and what happens when a deploy locks the owner out? 4. What makes an update to **stateful** services **undoable**? 5. How do the **private values** reach the real host? 6. How does the owner learn what is **urgent**? 7. What does the **next release** ask? 8. Where do the **quick checks** run?

## Results

Lab: the integrated host `host-t` and a small test host `host-v` ([the scripts](../../lab/), `lab/updates-u*.sh`; branch `exp/updates`, tag `exp-updates`). The VMs are nested and the lab's link downloads at about **5 MiB/s**: **times are lab times**, and the real machine will differ. One run was lost when two heavy builds starved the workstation's memory: the guest rebooted by itself (uptime 14 minutes afterwards; most likely its own panic-on-lockup setting, not confirmed from a crash dump); the tests were repeated one VM at a time.

### 1. What an update costs (U1, U1b, U2)

The same flake built with nixpkgs pinned at an old revision and at the branch's latest (`774debe`, 2026-10-02), the old closure copied into an **empty store** so that only what a machine running it would lack is counted.

| nixpkgs age | Packages changed | Fetched | To build here | Time |
|---|---|---|---|---|
| **4 days** (the running system) | not counted | **76 paths, 160.6 MiB** (593 MiB unpacked) | 58 small derivations | **38 s** |
| **30 days** | 86 | **914 paths, 1.7 GiB** (5.3 GiB unpacked) | 482 derivations | **353 s** |
| **90 days** | 154 | **914 paths, 1.7 GiB** (5.3 GiB unpacked) | 482 derivations | **423 s** |

- **The cost has two sizes.** A bump inside one build of the base (glibc, stdenv) is small; **one that crosses a mass rebuild**, as the last 30 days did (glibc 2.42-67 to 2-84), re-fetches almost everything. 30 and 90 days cost the same because both cross it.
- **Nothing heavy is compiled here.** The "derivations to build" are configuration and joins (`etc-*`, unit files, `initrd`, `hwdb`, Nextcloud with its apps, PostgreSQL with its extensions); nginx, the kernel, ZFS and the services' own packages arrive from the cache (checked by name for nginx, the kernel and the ZFS module). **An update is a download**, not a build, so building on the server is fine.
- **What moved in 30 days:** Nextcloud 33.0.8 to 33.0.9, its `oidc` app 2.0.9 to 2.4.1, nginx 1.30.4 to 1.30.5, Podman 5.8.6 to 5.8.7, Vaultwarden 1.37.2 to 1.37.3, systemd 260.2 to 260.4, OpenSSL, curl, kernel 6.18.49 to 6.18.54. **In 90 days also** PostgreSQL 17.10 to 17.11, Syncthing 2.0.15 to 2.1.3, Vaultwarden 1.36.0 to 1.37.3, OpenSSH 10.3 to 10.5, ZFS 2.4.2 to 2.4.4, kernel 6.18.38.
- **The disk:** each generation's closure is **4.7 GiB**; an update that crosses a mass rebuild adds 5 GiB at once, kept for the rollback. **The real system disk is 119 GB** and the flake had **no garbage collection**. Added in `base.nix` and tried: weekly `nix-gc` with `--delete-older-than 14d`, weekly store deduplication, ten boot entries, weekly Podman image prune. In the lab a collection of the leftover test closures **freed 12.4 GiB (22,067 store paths) in 18 seconds and the services kept answering**; the Podman prune left the in-use images alone. **Not tested over weeks**, and Podman's prune removes only untagged unused images (what a digest bump leaves behind).

**Applying a 30-day update to the running host** (`switch`, with a probe asking every service every 0.2 s): the switch took **14 s**; the services were silent for **PostgreSQL 10.0 s, Vaultwarden 10.7 s, Nextcloud 13.9 s, Immich 16.9 s, WebDAV 2.5 s**. It restarted `nginx`, `incus`, `sshd`, `dhcpcd`, `journald`, `udevd` and stopped and started the certificate and monitoring units, PostgreSQL and what depends on it. **A PostgreSQL restart alone** silences PostgreSQL for 0.4 s, Vaultwarden 1.1 s, Immich 7.1 s, Nextcloud not at all.

**A reboot** (for the new kernel): ssh answered **31 s** and every service **39 s** after the reboot command (the lab VM; the real machine's firmware, disks and the TPM unlock of [ADR 0005](0005-storage-layout-and-filesystem.md) are not in this number). That run did not change the kernel (the baseline already had it); **a new ZFS userland against an older loaded kernel module was not tried**, and neither was **a kernel update on a TPM-sealed disk**, which could ask for the passphrase.

### 2. Deploy methods and a deploy that locks the owner out (U3)

The test host deploys to itself over ssh; "locked out" means a deploy that removes the admin's keys, a realistic mistake.

| Method | A good deploy | A deploy that locks the admin out | Failed evaluation | Notes |
|---|---|---|---|---|
| **`nixos-rebuild switch --target-host`** (or run on the server) | **25 s** | **not tried with `switch`**: by its documented behaviour it succeeds, **ssh is gone**, and `switch` also makes the new generation the boot default | stops before changing anything (seen through `autoUpgrade`, which runs it) | nothing extra to install |
| **the same with `test`, then a reboot** | | locked out until a **power cycle (57 s)**; the reboot returns to the previous generation because `test` is not the boot default | | needs someone at the machine |
| **deploy-rs** (push, magic rollback) | **11 s** warm; **477 s the first time**, which compiled Rust (`activate-rs`, not in the binary cache) | **rolled back by itself**: locked out **34 s** (a 30-second confirmation timeout), ssh back, "Deployment ... failed, rolled back to previous generation" | not tried | an extra flake input and `deploy` outputs; a Rust build on the deploying machine |
| **comin** (pull, polls every 60 s) | **69 s** | **none seen** in the test or in the page read (the page mentions a testing branch: not tried) | the host is unchanged and **comin keeps running**; the error is in its log as `info` lines; **no unit fails**, so `UnitFailed` stays quiet; it serves 9 `comin_` metrics for Prometheus | a service on the host that pulls from a git remote; repair live in 69 s |
| **`system.autoUpgrade`** (pull, a timer) | **12 s** (started by hand) | no rollback | the unit **fails in 7 s** with the error in the journal: **`UnitFailed` raises a mail** (6 minutes, measured in [ADR 0015](0015-backup-verification.md)) | root must be able to read the repository; cannot pick what to apply; `allowReboot` and `rebootWindow` exist |

Not tried: **colmena** (comparisons describe it as a push tool like `nixos-rebuild`).

### 3. Services with state: what can be undone (U4)

On the integrated host with the drill's data:

| Test | Result |
|---|---|
| **Immich's older image** (v3.2.1, what v0 runs) started on the database that **v3.2.4 created** | it **starts and answers**, and logs "**Detected schema drift**"; whether every feature works was not examined |
| **PostgreSQL restart** | see above: 0.4 s to 7 s of silence |
| **Nextcloud 33 to 34** (a declared package change) | **16 s** to switch, working at 34.0.4.1 |
| **Going back to the previous generation** (`nix-env --rollback` and `switch-to-configuration`, what `nixos-rebuild --rollback` does) | **1 s, and Nextcloud is broken**: "**Downgrading Nextcloud from 34.0.4.1 to 33.0.9.1 is not supported and may corrupt your instance ... Restore a full backup**"; `nextcloud-setup` fails |
| **ZFS**: a snapshot of `tank/data` and `tank/postgres` in one command **before** the update | **50 ms** (42 and 50 in two runs) |
| **ZFS rollback** of the two datasets, then the services started again | **4.2 s**; **8 s from the start of the recovery to Nextcloud answering at 33.0.9.1 with all 5 test files**. The restore of [ADR 0014](0014-automation-and-restore-drill.md), from Borg and pgBackRest, took **167-240 s** on the same data |
| **`services.sanoid`** (a native module) with a short retention (24 hourly) on the two datasets | the module **took the snapshots** (`autosnap_..._hourly`, 0 B and 884 KiB) and delegates the ZFS rights to its own user; a later run in the same hour did not (the module's cache), **not examined**; **pruning over days was not tried** |

**So a NixOS rollback does not undo an update of a service that has migrated its data**; what undoes it is a copy of the data from before. A ZFS snapshot is a fraction of a second to take and seconds to return to; **a rollback to it loses everything written after it** (uploads, new passwords), which is why it is for the minutes around an update. The backups remain the way back for anything older.

### 3b. The security signal (U6)

`vulnix` against the system closure: **77 s**, **74 packages and 233 CVEs** reported, led by the Go bootstrap compiler, `yasm`, GStreamer, `cargo`, a Rust crate called `curl` (not curl), two **Incus patch files read as packages**, glibc builds. **Nearly all of it is build tools, name collisions or fixes the package already carries**: used as it is, it would be noise, and **a maintained whitelist is work with no end**. What does work without help: **nixpkgs refuses to build a package marked insecure** ([ADR 0011](0011-services.md) met this with Immich 2.7.5). So the signal for the exposed services is **their own advisories** (the table above) read weekly, not a scanner.

### 4. How new versions find us (U10, from the documentation)

| Tool | What it does here | Result |
|---|---|---|
| **Renovate** (works on private repositories) | opens a pull request for a new container digest or version; its `nix` manager reads the `flake.lock` inputs | **tried locally against this repository**: it found the **three flake inputs** (locked revisions) and, with a small regular expression in `renovate.json`, **three of the four container pins** (Immich server, Immich machine learning, Jellyfin); the fourth (Valkey) had **no version comment** and was missed, **now fixed** (`# 8-bookworm`). With two pins made to look old it proposed **Immich v3.2.1 to v3.2.4 (labelled `patch`, `non-major`, with the new digest)** and **Jellyfin 11.0 to 12.1 (labelled `major`)**: **the labels allow a different rule per kind**. Its `nix` manager is **beta and off by default**, and **refreshing `flake.lock` itself is a separate setting (`lockFileMaintenance`) that runs Nix**, and **the stock Renovate container has no `nix`** (checked): **not tried end to end** |
| **Dependabot** | a pull request per outdated flake input | supports Nix since April 2026 but **not private repositories** (GitHub's changelog); it reads Dockerfiles and compose files, **not image strings inside `.nix` files** (from its documentation, not tried) |
| **`update-flake-lock`** (a GitHub Action) | runs `nix flake update` on a schedule and opens a pull request | from its documentation; needs Nix set up in the job; **a pull request opened by an Action does not start other workflows** unless a token is used; **not tried** (it needs a GitHub run) |
| **by hand** | `nix flake update`, a digest copied from the registry | `nix flake update` took **28 s**; a digest needs a registry lookup and a hand edit (what the Renovate pins automate) |
| a script of ours | | **rejected under P1** |

### 5. How the private values reach the real host (U8)

Two designs, both built in the lab with an example private file (`home.example`, disks, a VPN peer, the secrets file):

| | **A. one flake, the private values an input replaced at build time** | **B. a private flake that imports the public one** (`tidepool.lib.mkHost ./host.nix`) |
|---|---|---|
| Builds | yes: the default input is the example, `--override-input private <the private repository>` replaces it | yes |
| Domain and disks taken from the private files | yes | yes |
| Lock files | **one**, the public repository's | two: the private one pins the public repository by revision |
| **Does the deployed nixpkgs equal the tested one?** | by construction | **yes, measured**: the private lock held `7fc6f2c2`, the public lock's revision; after the public lock moved to `774debe7` and `nix flake update tidepool` was run in the private flake it followed to `774debe7`; **a bare `nix flake update` with the public lock left behind did not move nixpkgs past it** (transitive inputs follow the public flake's own lock) |
| **What a forgotten step does** | `nixos-rebuild` **without** the override flag builds the **example host**: wrong disks, wrong domain, **on the real machine** | the real host exists **only** in the private flake: the public repository cannot deploy it |
| Update steps | one repository | `nix flake update tidepool` in the private one after the public one moves |

### 6. Where the quick checks run (U7)

On the lab host, `nix flake check` of both hosts (the real one with its example values):

| | Result |
|---|---|
| Closures | lab 4.74 GiB, example host 4.57 GiB, **4.80 GiB together** |
| **Evaluation only** (`--no-build`) | **11.8 s of CPU, peak memory 1.2 GB** |
| **A clean machine** (empty store, everything fetched, both hosts built) | **447 s wall, about 10 minutes of CPU on 4 vCPUs, peak memory 4.1 GB, 6.9 GB of disk** |
| A GitHub-hosted runner, **private repository** | 2 vCPU, 8 GB, 14 GB SSD: it **fits** (4.1 GB, 6.9 GB); the Free plan has **2,000 minutes a month** for private repositories (public ones are free); **KVM is reported available on standard runners** (a search result quoting GitHub's changelog, **not tried**) |
| The full restore drill | an 8 GB VM with four disks, 30 minutes: **not for a hosted runner**; stays on the owner's workstation |
| A NixOS VM test (`nixosTest`) of one module | would run the drill's pieces in CI; **not tried** (effort) |

### 7. The next release (U9)

The same flake evaluated against `nixos-unstable`, since 26.11 is not branched yet: **evaluates, in 11 s, with one informational warning** (Nextcloud: from 26.11 the module's default package moves on, and this configuration **already names its package explicitly**), **896 paths to fetch, 1.6 GiB**. The drill (about 30 minutes) is the proof before any real move; **26.11 itself is untested**.

## Criteria, in this order

1. **Reversible, measured:** every update has a way back that works.
2. **Tested = deployed:** the same revisions and lock.
3. **P1:** native modules and configuration, no script of ours.
4. **Time to a serious fix** for the exposed services.
5. **The owner's effort and the moving parts** (accounts, third-party actions, services on the host).

## Proposed decision (for the owner)

1. **Structure: design B.** The public repository holds the modules and the lock; a **private flake imports it** and holds the values and the secrets file; the real host is built only from the private flake. (Criterion 2 by measurement and the "forgotten flag deploys the example" accident closed.)
2. **Finding updates: Renovate for the container digests, weekly, grouped**, with the rule that **`major` is never merged without the owner and never alone**; for `flake.lock`, **a scheduled `update-flake-lock`-style pull request weekly** or, if the owner prefers fewer accounts and actions, **`nix flake update` by hand when a deploy is prepared (28 s)**. **Neither Renovate's lock refresh nor the Action was run end to end** (they need GitHub): the first setup is the test. Third-party Actions are **pinned by commit**.
3. **Cadence: a look every week** at the pull requests and at the four exposed services' advisories (24 high or critical in a year), **routine updates deployed monthly or when a serious advisory lands**; a critical one within days, by hand.
4. **Deploy: plain `nixos-rebuild switch`, run on the server or from the workstation with `--target-host`, by the owner, after the checks pass.** No extra tool: **deploy-rs** buys automatic recovery from a lockout at the price of a Rust build (477 s the first time) and extra flake plumbing, and at home the console is a few steps away; **comin** and **`autoUpgrade`** apply without a human and cannot tell a safe update from one that migrates a database. **For a change to SSH, the VPN or the firewall: `nixos-rebuild test` first, `switch` once the owner has logged in again**; a power cycle undoes a `test`.
5. **Undoing an update of a stateful service: a ZFS snapshot of the two datasets taken just before the deploy** (50 ms, seconds to return to), **plus the hourly Borg run**. **The owner decides how the snapshot is taken:** *(a)* **a line in the deploy runbook** (`zfs snapshot tank/data@pre-update tank/postgres@pre-update`, and `zfs destroy` after a good week): nothing to maintain, easy to forget; or *(b)* **`services.sanoid` with 24 hourly snapshots of those two datasets** (native, declared, a rollback point at most an hour old with no human step; **this reverses the owner's 2026-10-01 decision to have no scheduled snapshots**, taken when the alternative was a restore of minutes and unmeasured; the measured cost here is 50 ms to take and 884 KiB held, the real cost in space over weeks is **not measured**). Either way, **before an update that bumps Nextcloud, Immich, Jellyfin or PostgreSQL, run the two Borg jobs** (the second way back).
6. **Releases:** stay on the stable branch; **move to 26.11 within weeks of its release and before 26.05 ends on 2026-12-31**, rehearsed by the drill. **The owner's call is the real deployment's date:** deploying on 26.05 in October means moving again in December; **waiting for 26.11 in December means the first machine starts supported for seven months.** This configuration is ready for either (the evaluation against unstable passed).
7. **Reboot policy:** reboot when the kernel changes (compare `/run/booted-system/kernel` and `/run/current-system/kernel`) at a moment the family does not use the server; the lab says 39 s; **a TPM-sealed disk after a kernel update is a first-deployment check**.
8. **The checks: `nix flake check` on every pull request and push, in GitHub Actions on the private repository** (a hosted runner fits it; a few minutes a run, well inside the 2,000 free minutes), **the full drill on the owner's workstation** before each release move and after any change to the storage, backup, database or Incus modules, and **once a quarter** as a reminder.
9. **The disk:** the store collection, deduplication, boot-entry limit and image prune of `base.nix` stay (measured above).

## What this does not cover

- **GitHub Actions, Renovate's app and the Action end to end**: they need a GitHub run, and the repository's visibility and plan are the owner's.
- **The real link and disk**: update times are lab times (5 MiB/s).
- **Weeks of garbage collection, snapshot pruning and image pruning.**
- **A reboot that changes the kernel and ZFS**, and **a kernel update on a TPM-sealed disk**.
- **Colmena, a `nixosTest` of the drill, and `vulnix` with a whitelist.**
- **Immich older image beyond starting**; **comin's testing branch**.

## Open questions for the owner

1. **Design B** (a private flake importing the public one)?
2. **Renovate for the container digests**, and for `flake.lock` either **a weekly Action** or **by hand**? Is a **third-party GitHub Action, pinned by commit**, acceptable? Is the repository to **stay private**, or become public (Dependabot and free Actions minutes would follow)?
3. **How often**: weekly look and monthly deploys as above, or another rhythm?
4. **The rollback point:** the line in the runbook (a) or `services.sanoid` (b)?
5. **26.05 now or 26.11 for the first deployment?**
6. **Is a human to start every deploy?** (Proposed: yes.)

## Consequences

- `nixos/flake.nix` gains `lib.mkHost`; `base.nix` the store collection and the image prune; `services.nix` a version comment on the Valkey pin (so Renovate sees it); `observability.nix` a corrected threshold for the certificate-renewal timers.
- The deploy runbook (`docs/restore-drill.md`'s sibling, to write with the decision) gets: the pre-deploy snapshot, the two Borg runs, `test` before `switch` for network changes, the reboot check.
- The exceptions register does **not** change: nothing here is glue of ours (sanoid is a module).
- The pending list gets the untested items above.
