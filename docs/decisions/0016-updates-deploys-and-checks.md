# 0016. Updates, deploys, and where the checks run

- **Status:** accepted; the final shape of the deploy chain is in [ADR 0018](0018-deploys-by-the-server.md)
- **Date:** 2026-10-03
- **Phase:** 8, Updates and automation

## Context

The earlier phases decided and proved how the server is built, backed up, watched and restored. Nothing yet decided how it stays up to date, how a new version reaches the machine, what happens when a deploy goes wrong, or where the quick checks of [ADR 0014](0014-automation-and-restore-drill.md) run on their own. I wanted measurements before choosing.

Three facts frame it:

- Support has a date. NixOS 26.05, the release the flake is pinned to, gets security updates until 2026-12-31, and 26.11 is due at the end of November 2026.
- The exposed services publish security advisories all the time (below).
- The private values (domain, disks, VPN peers) must not enter the public repository ([ADR 0003](0003-secrets.md)); the way they reach the host decides how updates are built and tested.

## Requirements

- Must: no update reaches the machine unseen and irreversible. Any update that can change a service's data has a way back that works (measured, not assumed). A failed update is noticed by the channel of [ADR 0012](0012-observability.md). The private values never enter the public repository. What is deployed is what was tested (the same lock, the same revision). No script of ours in the path (P1); exceptions only in [the register](../exceptions.md).
- Should: exposed services updated within days of a serious advisory; routine updates cheap in time (a few minutes a week); the small system disk does not fill; the quick checks run without anyone remembering.
- Should not: unattended major-version changes of anything with state; a paid service; a build on the server that takes hours.

## What there is to update

| Component | Where its version is set | What an update does | Can NixOS roll it back? |
|---|---|---|---|
| The system (kernel, systemd, nginx, OpenSSH, Podman, ZFS, Borg, pgBackRest, Syncthing, Vaultwarden) | `flake.lock`, input `nixpkgs` | a new generation; services restart; a new kernel needs a reboot | yes, the previous generation is still installed |
| PostgreSQL 17 | nixpkgs (minor versions) | a restart | a minor version: yes. A major version is a manual dump and restore ([ADR 0006](0006-postgresql-version-and-immich.md)) |
| Nextcloud 33 | nixpkgs (`nextcloud33`) | `occ upgrade` on start | no: it refuses to go back (measured below) |
| Immich, Jellyfin, Valkey | the digest in `services.nix` | the container is replaced; Immich migrates its schema | the image can be put back, the data may not follow |
| Incus instances | per instance | not part of the flake | n/a |

The four services exposed to the Internet ([ADR 0008](0008-edge.md)) published 93 advisories in the year to October 2026, 24 of them high or critical: about two a month. A monthly look can leave a serious one open for four weeks; a weekly look shortens that to one.

## Results

Lab: the integrated host and a small test host (`lab/updates-u*.sh`). The VMs are nested and the lab's link downloads at about 5 MiB/s, so times are lab times and real hardware will differ.

### 1. What an update costs

The same flake built with nixpkgs pinned at an old revision and at the branch's latest, the old closure copied into an empty store so that only what a machine running it would lack is counted.

| nixpkgs age | Packages changed | Fetched | To build locally | Time |
|---|---|---|---|---|
| 4 days | not counted | 76 paths, 160 MiB | 58 small derivations | 38 s |
| 30 days | 86 | 914 paths, 1.7 GiB | 482 derivations | 353 s |
| 90 days | 154 | 914 paths, 1.7 GiB | 482 derivations | 423 s |

- The cost has two sizes. A bump inside one build of the base is small; one that crosses a mass rebuild (glibc, stdenv) re-fetches almost everything. 30 and 90 days cost the same because both cross it.
- Nothing heavy is compiled. The derivations to build are configuration and joins (`etc-*`, unit files, `initrd`, Nextcloud with its apps); nginx, the kernel, ZFS and the services' packages arrive from the cache. An update is a download, not a build, so building on the server is fine.
- Disk: each generation's closure is about 4.7 GiB, and an update that crosses a mass rebuild adds 5 GiB at once, kept for the rollback. On a small system disk that needs garbage collection: `base.nix` runs a weekly `nix-gc` (`--delete-older-than 14d`), weekly store deduplication, ten boot entries and a weekly Podman image prune. In the lab a collection freed 12.4 GiB in 18 seconds while the services kept answering. Not tested over weeks.
- Applying a 30-day update to the running host took 14 s; the services were silent for between 2.5 s (WebDAV) and 17 s (Immich), PostgreSQL 10 s. A reboot for a new kernel: ssh back after 31 s and every service after 39 s (lab VM, without the firmware and the TPM unlock).

### 2. Deploy methods, and a deploy that locks the admin out

The test host deploys to itself over ssh; "locked out" means a deploy that removes the admin's keys, a realistic mistake.

| Method | A good deploy | A deploy that locks the admin out | A failed evaluation |
|---|---|---|---|
| `nixos-rebuild switch` (on the server, or `--target-host`) | 25 s | ssh is gone, and `switch` made the new generation the boot default | stops before changing anything |
| the same with `test`, then a reboot | | locked out until a power cycle (57 s); the reboot returns to the previous generation | |
| deploy-rs (push, magic rollback) | 11 s warm, 477 s the first time (it compiles Rust) | rolled back by itself after 34 s | not tried |
| comin (pull, polls every 60 s) | 69 s | none seen | the host is unchanged and comin keeps running; no unit fails, so `UnitFailed` stays quiet |
| `system.autoUpgrade` (pull, a timer) | 12 s | no rollback | the unit fails in 7 s with the error in the journal, and `UnitFailed` raises a mail |

Colmena was not tried. `autoUpgrade` needs root to be able to read the repository and cannot pick what to apply, but it has `allowReboot` and a reboot window.

### 3. Services with state: what can be undone

| Test | Result |
|---|---|
| Immich's older image started on the database that the newer one created | it starts and answers, and logs "Detected schema drift"; whether every feature works was not examined |
| Nextcloud 33 to 34 (a declared package change) | 16 s to switch, working |
| Going back to the previous generation | 1 s, and Nextcloud is broken: "Downgrading Nextcloud from 34 to 33 is not supported and may corrupt your instance ... Restore a full backup" |
| A ZFS snapshot of the data and database datasets before the update | 50 ms |
| A ZFS rollback of the two datasets | 4.2 s; 8 s from the start of the recovery to Nextcloud answering at the old version |
| The restore of [ADR 0014](0014-automation-and-restore-drill.md) from Borg and pgBackRest on the same data | 167 to 240 s |

A NixOS rollback does not undo an update of a service that has migrated its data; what undoes it is a copy of the data from before. A ZFS snapshot is cheap to take and quick to return to, but a rollback to it loses everything written after it (uploads, new passwords), so it is only for the minutes around an update.

### 4. The security signal

`vulnix` against the system closure took 77 s and reported 74 packages and 233 CVEs, nearly all of it build tools, name collisions or fixes the package already carries. Used as it is it would be noise, and a maintained whitelist is work with no end. What works without help is that nixpkgs refuses to build a package marked insecure. So the signal for the exposed services is their own advisories, read weekly, not a scanner.

### 5. How new versions find the repository

| Tool | Result |
|---|---|
| Renovate (works on private repositories) | tried locally: it found the three flake inputs and, with a small regular expression in `renovate.json`, the container pins. It proposed an Immich patch update labelled `patch` and a Jellyfin update labelled `major`, so a different rule per kind is possible. Its `nix` manager is beta, lock refresh is a separate setting that runs Nix, and the stock container has no `nix` |
| Dependabot | supports Nix but not private repositories, and does not read image strings inside `.nix` files |
| `update-flake-lock` (a GitHub Action) | from its documentation: needs Nix in the job, and a pull request opened by an Action does not start other workflows unless a token is used |
| by hand | `nix flake update` took 28 s; a digest needs a registry lookup and a hand edit |
| a script of ours | rejected under P1 |

### 6. How the private values reach the host

Two designs, both built in the lab with an example private file:

| | A. one flake, the private values an input replaced at build time | B. a private flake that imports the public one |
|---|---|---|
| Lock files | one, the public repository's | two: the private one pins the public repository by revision |
| Does the deployed nixpkgs equal the tested one? | by construction | yes, measured: after the public lock moved, `nix flake update` in the private flake followed it |
| What a forgotten step does | `nixos-rebuild` without the override flag builds the example host: wrong disks, wrong domain, on the real machine | the real host exists only in the private flake: the public repository cannot deploy it |

### 7. Where the quick checks run

`nix flake check` of both hosts: evaluation alone takes 12 s of CPU and 1.2 GB; a clean machine with an empty store takes about 7.5 minutes of wall time and 4.1 GB of memory, 6.9 GB of disk. A GitHub-hosted runner (2 vCPU, 8 GB) fits it. The full restore drill needs an 8 GB VM with four disks and half an hour, so it is not for a hosted runner and stays on a workstation. A NixOS VM test of one module would run the drill's pieces in CI; not tried.

### 8. The next release

The same flake evaluated against `nixos-unstable`, since 26.11 was not branched: it evaluates in 11 s with one informational warning (Nextcloud's default package moves on; the configuration already names its package). The drill is the proof before any real move; 26.11 itself is untested.

### 9. A module that goes stale

The risk of a module that stops following upstream was not measured before. On the stable branch, days from an upstream release to its arrival: Nextcloud median 1.8 (max 4.3), Vaultwarden median 0.7 (max 7), Syncthing median 4.5 (max 32). A new Nextcloud major reaches a release only with the next one; when upstream ends support of a major the package is dropped and the build stops, which is a loud failure, not a silent one. The case that no alert catches is a package that stops coming and nobody notices; [ADR 0017](0017-version-watch-push-and-nas.md) adds the weekend version watch for it.

The way out, tried: Nextcloud started from the official container image on the same data and the same PostgreSQL database. The state to carry is three things, all outside the module's store paths: `config/`, `data/` and the database. The container served the same files in 7 seconds once the image was pulled. The module's settings live in a store JSON file and had to be stated again, and the module's apps are not in the container. So the exit is an afternoon of work, not a redesign, provided the data stays under `/srv/data` and the database in PostgreSQL.

## Decision

1. **Structure: design B.** The public repository holds the modules and the lock; a private flake imports it and holds the values and the secrets file. The private lock pins a public revision, and the pull request that moves the pin is the deploy: two merges.
2. **Finding updates: Renovate**, run on the server with a machine user's token (module `renovate.nix`), for the container digests and the lock, in a Monday pull request. `major` is never merged alone.
3. **Who starts the deploy: the server**, when a change is merged (`system.autoUpgrade`, every ten minutes from Monday to Saturday). comin and a runner on the server were compared and not chosen.
4. **The way back for stateful services:** no scheduled snapshots. Every backup method runs before a change is activated (`system.preSwitchChecks`), and a restore is the way back from a stateful upgrade. For a change to SSH, the VPN or the firewall, `nixos-rebuild test` first and `switch` once logged in again.
5. **Releases:** 26.05 first, 26.11 afterwards, through the same pipeline and rehearsed by the drill.
6. **Reboots:** when the kernel changes, in a window; a kernel update on a TPM-sealed disk is a first-deployment check ([ADR 0005](0005-storage-layout-and-filesystem.md)).
7. **The checks:** `nix flake check` on every pull request, in GitHub Actions; the full drill on a workstation before each release move and after any change to the storage, backup, database or Incus modules.
8. **The disk:** the collection, deduplication, boot-entry limit and image prune of `base.nix` stay.
9. **Keeping the modules:** Nextcloud, Vaultwarden and WebDAV stay modules rather than containers, with the container exit above as the way out.

## What this does not cover

- GitHub Actions, Renovate's lock refresh and the Action end to end: they need a GitHub run.
- The real link and disk: update times are lab times.
- Weeks of garbage collection and image pruning.
- A reboot that changes the kernel and ZFS together, and a kernel update on a TPM-sealed disk.
- Colmena, a `nixosTest` of the drill, and `vulnix` with a whitelist.

## Consequences

- `nixos/flake.nix` gains `lib.mkHost`; `base.nix` the store collection and the image prune; `services.nix` a version comment on the Valkey pin (so Renovate sees it); `observability.nix` a corrected threshold for the certificate-renewal timers.
- The deploy runbook gets the two Borg runs before an update, `test` before `switch` for network changes, and the reboot check.
- The exceptions register does not change: nothing here is glue of ours.
- The pending list gets the untested items above.
