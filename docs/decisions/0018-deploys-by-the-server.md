# 0018. Deploys: the server pulls what was merged, the backups run first, the private repository

- **Status:** **decided by the owner (2026-10-03):** `system.autoUpgrade` every 10 minutes **on Monday to Saturday**; every protection on the public `main`; **two merges**; **automatic reboot after a new kernel** (a window, 06:00 to 07:00); **Renovate on the server**; built and measured in the lab, **the reboot also with the encrypted layout and the TPM (2026-10-05)**; **the first deployment on 26.05, then the move to 26.11, and the deploy timer without Sunday are decided (2026-10-05)** (section 12); **nothing is on the real server, no real TPM or firmware has been tried, nothing ran against GitHub**
- **Date:** 2026-10-03
- **Phase:** 8, Updates and automation (follow-up of [ADR 0016](0016-updates-deploys-and-checks.md) and [0017](0017-version-watch-push-and-nas.md))

## Context

The owner's decisions of 2026-10-03:

- **The deploy is started by the server, when a change is merged.** (Not by the owner at a keyboard, not by a GitHub job pushing to the server.)
- **The public repository is public; the private one, which holds the values, is not**: how the server reads it had to be worked out.
- **No scheduled (hourly) snapshots.** Instead, **every backup method runs before an update.**
- Unsure between **comin** and **a runner on the server**.
- **Nextcloud 33 and PostgreSQL 17 stay** for now (the rest is decided later, [ADR 0017 section 9](0017-version-watch-push-and-nas.md)).

## 1. Who applies the change

| Option | Tried | Result |
|---|---|---|
| **A. `system.autoUpgrade`** (a NixOS module: a timer runs `nixos-rebuild switch` against the flake) | **yes, this ADR** (`lab/deploy-u16.sh` to `u18`) | works: below. In nixpkgs, no extra flake input; **a failure is a failed unit** (`UnitFailed` mails, [ADR 0015](0015-backup-verification.md)); idle cost about **1 s of CPU every tick** |
| **B. comin** (pulls, polls every 60 s) | [ADR 0016](0016-updates-deploys-and-checks.md) (a deploy took 69 s); **not tried this round with the backups before the switch, nor its idle cost** | a **separate flake** (not in nixpkgs 26.05: the module is not offered by `nixos-option`); an evaluation error is **only an `info` line in its log, no unit fails**, so the alert stays quiet; it serves 9 metrics for Prometheus; its idle cost was not measured |
| **C. A GitHub runner on the server** (`services.github-runners`, a deploy job on `main`) | **no**: it needs a GitHub registration; the module exists | GitHub's own advice is to use self-hosted runners **only with private repositories** because a pull request to a public one can run code on the machine ([secure use](https://docs.github.com/en/actions/reference/security/secure-use)); a deploy job there is **root on the server**; a token and a permanent connection to GitHub; **it adds nothing the pull does not already do** |
| **D. The owner runs `nixos-rebuild` after a merge** | ADR 0016 | the baseline; against the owner's decision |

**Decided by the owner, 2026-10-03: A.** It is the only one that is a maintained NixOS module **and** makes a failed deploy loud. comin's advantages (60-second polling, metrics) are not needed for a home server (10 minutes is enough), and the runner brings the most risk for no gain.

## 2. The design

```
public repository (modules, flake.lock, CI)         private repository (values, encrypted secrets, a flake that imports the public one)
   |  pull request: Renovate + `nix flake check`         |  the owner pushes a change of values
   |  the owner merges  ------------------------------+  |
                                                      v  v
   the SERVER, every 10 minutes (system.autoUpgrade):
     1. fetch the private repository over ssh with a read-only DEPLOY KEY (GitHub's host key pinned)
     2. replace the public input by its newest commit (--override-input)
     3. evaluate; if the system is the one that runs: stop (a tick costs about 1 s)
     4. build it
     5. BEFORE activating (system.preSwitchChecks): Borg of everything, Borg offsite, a pgBackRest diff; if one fails, STOP
     6. switch
   a failed step = a failed unit = a mail in 5 minutes
```

- **A merge in the public repository is the deploy.** The merge is the owner's approval: nothing reaches the server that was not merged to `main`. A change of values is a push to the private repository's `main`.
- **The deployed revision of the public repository** is not recorded in the private repository's lock (the server takes the newest each time); `nixos-version --configuration-revision` shows the private one. If a record is wanted, the private lock can be bumped by a pull request instead (**open decision 5**: one merge or two).
- **A new kernel waits for the owner's reboot** (`allowReboot = false`), as the disk is unlocked by the TPM.
- **A major upgrade of Nextcloud or PostgreSQL** is a deploy like any other: it is deliberate because it is a merge, and the backups before it are the only way back (below).

## 3. Measured in the lab host (two local bare repositories stand in for the two GitHub repositories)

| Test | Result |
|---|---|
| **Idle ticks** (nothing changed, a tick every minute) | **about 1.0 s of CPU, 4 s of wall time, 25 MB**; the generation does not change; **no backup runs** (the check compares the incoming system with the running one) |
| **A merge in the public repository** | the new marker was live **61 s and 81 s** later (a one-minute timer in the lab: in production up to the interval plus about a minute) |
| **The backups run before the switch** | the Borg archive (15:24:13) and the pgBackRest diff (15:24:23) **precede** the activation (about 15:24:30) |
| **A backup that fails** (the Borg repository of everything made to disappear) | **the change is not activated** (the old marker stays), `nixos-upgrade` fails, the `UnitFailed` mail arrived **390 s** after the merge; when the repository came back the **next tick applied the change after 71 s** (self-healing) |
| **A commit that does not evaluate** | the unit **fails** with the syntax error in the journal, the running system is untouched, and the **fixing commit was applied 54 s later** |
| **`--update-input`** | works, but prints **"deprecated alias ... will be removed in a future version"** on every tick |
| **`--override-input`** (what the module uses now, `tidepool.deploy.inputs`) | the same behaviour, **no warning**; a merge was live in 81 s |
| **The deploy key over ssh** (a key that is allowed only `git-shell`) | the flake is fetched; **a shell command or reading another file is refused**; the key **revoked** gives `Permission denied (publickey)`; **a changed host key is refused** ("REMOTE HOST IDENTIFICATION HAS CHANGED") |
| **GitHub itself** (`lab/deploy-u18.sh`) | the key is a root-only sops secret (`root:root 400`), ssh uses it **only for github.com**, GitHub's ed25519 host key is **pinned** (fingerprint `SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU`, the one GitHub publishes at `api.github.com/meta`), and a real connection **reached GitHub and was refused only because the lab key is not registered**; a wrong pinned key is refused |

**A defect of mine, found by the test and fixed:** the first version of the pre-switch check called `readlink` by its bare name; the check script runs with an almost empty PATH, the command was not found, the condition read as false, and **the change was activated without its backups, in silence**. It is now written with the full path of every command and with `set -eu`, so **a check that cannot run stops the switch**. The test that found it is the one that looks at the Borg archive time against the activation time; a deploy that "worked" proved nothing.

**A test mistake, also recorded:** unmounting the 16 TB disk did **not** make the backup fail (systemd mounts it again for `RequiresMountsFor`); the failure had to be made by removing the repository.

## 4. The private repository: how the server reads it

The server needs the private repository to build, so it must hold **a credential** for it; the aim is the smallest one.

| Way | Result |
|---|---|
| **A. A deploy key** (an ssh key registered on that one repository, **read-only by default**, no expiry; [GitHub docs](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys)) | **built and tried**. Generated **on the workstation**, **encrypted into the private repository's sops file** (`deploy-key`), delivered by sops-nix at activation as a root-only file; GitHub's host key pinned in the configuration. Whoever steals it can **read** a repository that holds **no secret in clear** (values, and a sops file they cannot open). It is revoked in GitHub's settings and rotated by editing one secret |
| B. A fine-grained access token (`nix.settings.access-tokens`) | not built: it **expires** (a fine-grained token has an expiry date), so someone must renew it, and a lapse means no deploys |
| C. A bare repository **on the server**, the owner pushing over the VPN | not tried: **no GitHub credential at all**, but the private repository then lives only on the server (the Borg copy) and the workstation: no third copy, no pull requests on the values |
| D. The values in the public repository, encrypted | **not possible**: Nix needs the values in clear **when it evaluates** (the domain is used in expressions); sops decrypts at activation, not at evaluation |
| E. The owner copies the values at each deploy | against the decision that the server starts the deploy |

**Bootstrap, in order:** the owner creates the private repository; generates the deploy key on the workstation; encrypts its private half into the private sops file; adds its **public half** to the private repository as a **read-only deploy key**; installs the machine from the workstation's clone of the private repository (`nixos-install --flake`, the age key at hand); from then on the server fetches by itself. **Rotation:** a new key into the sops file, the new public half on GitHub, deploy, remove the old one.

## 5. Backups before an update, and no snapshots

The owner's rule (no scheduled snapshots; run the backup methods before an update) is **built**: `system.preSwitchChecks` runs **Borg of everything, Borg offsite and a pgBackRest differential backup** before a change that differs from the running system, and **stops the switch if any fails**. Consequences, stated plainly:

- **The way back from a stateful upgrade is a restore**, not a rollback: NixOS rolls the configuration back but **not** Nextcloud's or PostgreSQL's data ([ADR 0016](0016-updates-deploys-and-checks.md): Nextcloud refuses a downgrade). With a ZFS snapshot that would take seconds (50 ms to take, 4 to 8 s to roll back, measured there); with a backup it takes the **restore drill's time** ([ADR 0014](0014-automation-and-restore-drill.md)). A one-off snapshot just before a deploy (not a scheduled one) would cost almost nothing and is **not adopted**, by the owner's choice; it can be added in one line to the same check.
- **A deploy waits for the backups.** Borg's jobs wait up to 12 hours for a lock ([ADR 0015](0015-backup-verification.md)), so a deploy that arrives during the Sunday checks waits for them.
- **Every changing deploy pays for the backups**, even a trivial one: minutes in the lab, more with the real data. That is the price of the rule, accepted.

## 6. What is written for GitHub (not run there)

- **`.github/workflows/check.yml`**: `nix flake check` on every pull request and push to `main`, with the two actions **pinned by commit** (`actions/checkout` v7.0.1, `cachix/install-nix-action` v31.11.1); the repository is public, so the minutes are free; both hosts build and the version-watch rules run their unit test. **Not run on GitHub.**
- **`renovate.json`**: Monday morning, a grouped pull request for the container pins (`image = "repo:tag@sha256:..."`), `flake.lock` maintenance, a **major never merged without the owner**, the Actions pinned by commit. **Tried locally** (`renovate --platform=local` in the lab host): the config validates, and it **found all four container pins** (Valkey, Immich server and machine learning, Jellyfin) and the `nixpkgs` input and planned the branch `renovate/container-updates`. Whether Renovate runs as GitHub's app or on the server (`services.renovate`) is **open decision 3**.

## 7. Protecting the public `main` (decided: all of it)

`.github/rulesets/main.json` is a GitHub **ruleset** for the default branch, to be imported once the public repository exists (`gh api -X POST repos/OWNER/REPO/rulesets --input .github/rulesets/main.json`). What each rule stops:

| Rule | Stops |
|---|---|
| a pull request is required, **1 approval**, an approval that is **not** the last pusher's, stale approvals dismissed on a new push, threads resolved | a direct push to `main`; a bot or token that opens a pull request and merges it by itself |
| **the `flake-check` job must pass**, on a branch up to date with `main` | a change that does not build, or breaks the version-watch rules, reaching the server |
| **squash merges only** (linear history) | merge commits that hide a change; and, because **GitHub signs the squash commit it creates** (its documented behaviour, not tried here), it satisfies the next rule for every author, bots included |
| **signed commits** required | an unsigned commit pushed by a stolen token |
| **no force push, no deletion** of `main` | rewriting or removing what the server may already have deployed |
| bypass: the **repository admin role, only through a pull request** | the owner can merge their own pull request (GitHub does not let an author approve their own); nobody can push to `main` directly, the owner included |

**Settings next to it** (a checklist, in the public repository's settings): Actions run with a **read-only token** by default (the workflow also says `permissions: contents: read`); **fork pull requests need approval before their workflows run**; **secret scanning with push protection** (free on a public repository); **private vulnerability reporting**; passkeys or two-factor on the owner's account.

**Limits, plainly:** (1) the owner's GitHub account is the root of trust: an attacker who takes it over can change the ruleset, so the account's own security is what matters most; (2) **rulesets are enforced only on public repositories on the free plan**, so this cannot be switched on in the current private repository (its ruleset list answered empty; creating one was not tried) but in the **fresh public one**; (3) the `actor_id` 5 for the admin role and the exact field names are from GitHub's documentation (**checked at the import: accepted**); (4) the ruleset **guards the deploy**: every commit that reaches `main` and changes the host's system is on the server within 10 minutes (section 8).

**Done on the public repository (2026-10-06):** the ruleset is imported and active; a direct push to `main` is refused ("Changes must be made through a pull request", "Required status check `flake-check` is expected"). Next to it: Actions run with a read-only token and cannot approve pull requests, workflows of pull requests from forks need approval for every external contributor, secret scanning with push protection and private vulnerability reporting are on.

## 8. One merge or two (the owner asked to understand)

**What the two are.** *One merge:* the server follows the public repository's `main` (`tidepool.deploy.inputs`), so **merging a pull request in the public repository is the deploy**. *Two merges:* the private repository's `flake.lock` **pins** one public revision, the server deploys **exactly that**, and a **second pull request, in the private repository, moves the pin** (`private-repo-template/.github/workflows/bump-public.yml` opens it daily; merging it is the deploy). Both are built; the module's default (`inputs = {}`) is the second.

| | One merge | Two merges |
|---|---|---|
| Approvals | one (the public pull request) | two: the public one, then the pin's |
| **Who can put code on the server** | anyone who can write the public `main` (the ruleset is the only gate) | **also needs write access to the private repository**, which no outsider and no Renovate token has |
| **A record of what is deployed** | none in git (the server takes the newest each time) | **the private repository's history**: one commit per deployed public revision, with the list of public commits in the pull request |
| **Going back** | revert in the public repository (affects the example and the lab as well) | **revert the pin's commit in the private repository**: the server returns to the previous public revision |
| **When it deploys** | within 10 minutes of the merge, wherever the owner is | the owner **chooses the moment** by merging the pin (the next morning, after a coffee) |
| What it costs | nothing | one more click per deploy; a daily workflow (private repository, a few minutes of the free 2,000) |
| Rebuilding from the private repository alone | uses a stale lock unless overridden | **exact**, and the public lock's `nixpkgs` comes with it (measured in U8: the private lock follows the public one) |

**Measured:** a commit that changes **only documentation** in the public repository **did not change the system and ran no backup** (the tick found the same system); so merges that touch only `docs/`, the lab or the examples **do not reach the server's backups or switch** in either design.

**What does not change:** the account root of trust (section 7, limit 1): with the GitHub account taken over, both repositories fall.

**Decided by the owner, 2026-10-03: two merges.** The second gate is on a repository that no bot can write, the pin gives an audit trail and a clean way back, and it lets the owner pick the moment. The price is one click. `inputs` is the switch: leave it empty (two merges) or set it to the public URL (one). **Tried in the lab with the template made into a private repository** (`lab/private-repo-u24.sh`, 2026-10-05; **the real public layout**, the flake in `nixos/` read as `git+file://...?dir=nixos`, which the earlier tests did not cover): the lock pins the public revision and the **public lock's `nixpkgs`**; **the real host builds** (225 s, a 6.2 GiB closure: the encrypted layout, WiFi, firmware, the NAS, push, deploy and Renovate); **the disko script touches neither the 16 TB nor the 2 TB disk**; the pin moves with `nix flake update tidepool`, as the workflow does; a **docs-only public change leaves the system identical** (the same store path: no deploy, no backup) and **a change to a module changes it** (it would deploy). **Not tried on GitHub:** the workflow itself (it needs a repository and the setting that lets Actions open pull requests).

## 9. A new kernel: the reboot

**How NixOS decides.** After a switch it compares `/run/booted-system` (kernel, initrd, kernel modules) with the new system; `tidepool.deploy.reboot.allow` turns the automatic reboot on and `window` limits it to a time of day.

**Measured in the lab host** (kernel 6.18.54 to 6.12.111, a real change):

| | Result |
|---|---|
| **Reboot off** (the default) | the new kernel is **activated but not running**: the machine kept 6.18.54 for as long as it was left; the Nix-written file says **6.12.111**, the node exporter's `uname` says **6.18.54** |
| **The warning** | `RebootPending` (the activated kernel against the running one) **returns the series** while they differ and **is empty after the reboot**; it fires after a day (**unit-tested**: silent at 12 h, firing at 30 h, silent after the reboot); the mail goes by the normal route |
| **Reboot on** | the deploy ran the backups, switched, **rebooted by itself**; ssh was **down for about 20 s**; afterwards the new kernel ran, **no unit had failed**, ZFS was online, PostgreSQL, Immich, Nextcloud, Vaultwarden, Prometheus and Alertmanager answered, the timers were back |
| A detail | the module re-schedules the reboot (`shutdown -r +1`) **at every tick**: with the lab's one-minute timer that postponed it by about three minutes; with 10 minutes it does not matter |

**What was not tried, and it decides:** a **kernel update on the real disk layout, with LUKS unlocked by the TPM and Secure Boot through lanzaboote**: whether the machine boots by itself after a kernel update, or asks for the passphrase, is **unknown** (it is in [pending](../pending.md) since phase 2) and a lab VM has neither. An unattended reboot that stops at a passphrase prompt is a machine that is down until the owner arrives.

**Other things to weigh:** kernel point releases come about **weekly** (6.18.54 to 6.18.55 within days), so allowing the reboot means a reboot about **weekly**, about a minute each; a reboot interrupts a running Borg job (it resumes at the next hour); without a reboot the **fixes of the new kernel do not apply**, which is what `RebootPending` is for; the window cannot skip a day (the Sunday checks at 04:30 can run long: a window after them, say 06:00 to 07:00, is the safest).

**Decided by the owner, 2026-10-03: the reboot is allowed, in a window of 06:00 to 07:00** (**reopened and settled on 2026-10-05**: it needs the TPM alone, which the owner chose knowing it is the weaker option ([ADR 0005](0005-storage-layout-and-filesystem.md)); **in the lab a kernel change followed by a reboot opened the disks by itself**, PCR 7 unchanged; real hardware is still untried) (in the private template; the module's default stays off). The owner expects the TPM to work; that is **the one thing that can still undo this**, so the conditions are written down: **the TPM sealed to PCR 7 only** (the Secure Boot state and the signing key, which a kernel update does not change) **and not to the kernel image, and no PIN at boot** (see [ADR 0005](0005-storage-layout-and-filesystem.md), updated), and **the first kernel update rehearsed at the console** (`nixos-rebuild boot`, then a reboot) before the machine is left alone. **If the machine does not come back, the heartbeat stops and Healthchecks.io mails within minutes** ([ADR 0012](0012-observability.md)): a stuck boot is noticed, not silent.

**What the window test showed** (`lab/deploy-u20-window.sh`, found by a first attempt that rebooted outside the window):

- **With the reboot allowed, a deploy that changes the kernel is only INSTALLED**: the script runs `nixos-rebuild boot` (the new system becomes the boot default **and is not activated**), then compares the kernels: equal, it runs `switch`; different and **outside the window**, it prints **"Outside of configured reboot window, skipping."** and stops, **successfully**; different and inside, it schedules the reboot.
- **Measured:** outside the window the machine kept running the old kernel (the boot default had the new one); **a second merge while the reboot was pending was not activated either** (a marker file stayed absent); in the window the first tick scheduled the reboot (20:53, the window opened at 20:52), **20 s of downtime**, and **after the reboot the held second merge was live**.
- **Consequences:** (1) **everything merged while a reboot is pending waits for the reboot**, not only the kernel; (2) **a change of the window itself is read from the script that is active**: when it arrives together with a kernel change, the **old** window decides (the first attempt rebooted at once under the previous all-day window); change the window in a deploy of its own; (3) `RebootPending` compares the **activated** system with the running kernel, so it **does not cover this mode** (nothing is activated); a reboot that never comes (the window passes every day, so at most a day) is not signalled, only a machine that does not return; (4) the pre-switch backups run when the new system is **installed**, up to a day before the reboot; the hourly Borg jobs cover the hours in between; (5) a unit that fails after the switch (in the lab a Nextcloud unit whose data was newer than the package) makes `nixos-upgrade` fail too: a failure anywhere in a deploy is loud.

**With the encrypted layout and the TPM** (`lab/deploy-u22-encrypted.sh`, 2026-10-05: the lab host on UEFI, Secure Boot on, every volume sealed to PCR 7, an emulated TPM): the same sequence, and it holds:

| Step | Result |
|---|---|
| A kernel change is merged; the server installs it **outside** the window | the **Borg archives rose from 3 to 5** before it (the pre-switch backups), the **new boot image was installed and signed** with the owner's key (`sbctl verify`), the machine **kept running the old kernel**, "Outside of configured reboot window, skipping" |
| A second merge arrives while the reboot is pending | held (the marker file still the old one) |
| **The window opens (11:01 to 11:27)** | the machine **rebooted by itself at 11:06** (the first tick that completed in the window), **back in 27 s**, **no passphrase asked**, **kernel 6.12.111**, the held merge **live**, **Secure Boot still on, PCR 7 unchanged**, ZFS online, **no failed unit**, Immich and Vaultwarden answering |

The rebuild from blank with the same layout also passes ([restore-drill.md B2](../restore-drill.md): **14 checks, 0 failed units**; the **signing keys come back from Borg**, so the firmware's old keys still accept the new boot images and **the 2 TB disk's old TPM seal still opens it**). **Still untried: the real firmware and TPM** (a desktop board with the platform's firmware TPM, [ADR 0005](0005-storage-layout-and-filesystem.md)).

**The window and the Sunday checks.** The borgmatic checks start on **Sunday at 04:30** and verify **every byte of every archive** of a 14.6 TB repository: on the real data they may last **hours** (not measured). A reboot at 06:00 would cut them (cleanly: systemd stops the unit, no alert, the next run is a week away). So **the deploy timer runs Monday to Saturday** (`interval = "Mon..Sat *:0/10"`, in the private template): **no tick on Sunday, so no reboot on Sunday**; a change merged on a Saturday evening or a Sunday is installed on Monday at 00:00 and the reboot comes at 06:00 that day. The hourly Borg job at 06:00 may be cut by a reboot; it resumes at the next hour. If the first real Sunday check turns out to be short, the exclusion can go.

## 10. Renovate: GitHub's app or the server

The two things Renovate does are **different in kind**: the **container pins and the Actions' commits** (it only needs the registries and GitHub), and **refreshing `flake.lock`** (it must **run Nix**).

| | GitHub's app (Mend's hosted Renovate) | On the server (`services.renovate`) |
|---|---|---|
| **Identity** | its own **`renovate[bot]`**, not an admin | **a token**: a fine-grained token acts **as its owner** |
| **A secret on the server** | **none** | **yes**, with write access to pull requests and contents of the public repository, kept in sops; it **expires**, so a lapse must be noticed |
| **Do the protections hold?** | **yes**: the bot cannot merge (it needs an approval it cannot give itself) | **only with a separate machine account**: with the owner's token the bot **inherits the owner's bypass** (section 7) and could merge its own pull request |
| **Container pins, Actions** | yes | yes |
| **`flake.lock`** | **probably not**: the stock Renovate container **has no Nix** (checked in ADR 0016); the hosted app's image was **not checked**: install it and see whether a `lock-file-maintenance` pull request appears | **yes**: the module takes `runtimePackages` where `nix` and `git` go |
| **Cost on the server** | nothing | **924 MB of memory at the peak, 38 s of CPU in 67 s** for one local lookup run (measured in the lab host); weekly, on this machine |
| **Who sees the repository** | Mend, **for the public repository only** (do not install it on the private one: it would see the values) | nobody outside |
| **When it fails** | silently (a dashboard issue) | **a failed unit**: the `UnitFailed` mail |

**Decided by the owner, 2026-10-03: Renovate on the server** (`modules/renovate.nix`, off by default, `tidepool.renovate.enable`; the private template turns it on). The hosted app's doubts (no Nix, the identity) are avoided; the price is a token on the server, so the **token belongs to a machine user** (a second free GitHub account with the **write** role, not admin: the ruleset's bypass is for the admin role, so the bot **cannot** approve or bypass), kept in sops as `renovate-token`, **fine-grained to the public repository only** (contents and pull requests). It **expires**; the day it does the unit fails (below).

**Measured in the lab host** (`lab/renovate-u19.sh`; the token is a dummy, GitHub refuses it):

| | Result |
|---|---|
| The module | the configuration is **validated at build time** by Renovate's own validator; a **weekly timer** (Monday 04:30); a **dynamic user**; **`nix` and `git` in its PATH**; the token reaches the unit as a **systemd credential** (in no environment variable and not in the unit file) |
| **A lapsed or wrong token** | the unit **fails in 5 s** with "github.com token 401 unauthorized ... Authentication failure"; the **`UnitFailed` mail** names it (about 6 minutes, with the other failed unit of that moment) |
| **Nix under the unit's kind of user** (a dynamic user, its own state directory, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `NoNewPrivileges`) | **`nix flake update` works: 25 s**, "Updated input" |
| Memory | **364 MB** for the run that stopped at the refused token; **924 MB at the peak** for a full local lookup run (earlier): a weekly minute on this machine |
| `nix.settings.experimental-features` | **was not set anywhere** in the flake: `nix flake update` as that user (and by the admin at a shell) would fail; it is now in `base.nix` |

**Not tried:** the pull requests themselves (it needs the public repository and the machine user); **whether Renovate's `lockFileMaintenance` branch is produced** (the local platform does not make it, with or without Nix at hand: only the container pins' branch appeared); the first real `flake.lock` pull request will show it.

## 11. What this does not do

- **It trusts the public repository's `main`**: whoever can merge there puts code on the server. Branch protection with the CI check required, and the owner as the only merger, are **open decision 4**.
- **It does not reboot by default**, and when it does the TPM case is untried (section 9).
- **The poll is not instant**: a merge is applied within the interval (10 minutes in the module) plus the build and the backups.
- **Not tried:** comin with the backups before the switch and its idle cost; a runner; the whole flow against GitHub; the real data's backup times; a deploy that fails the **build** halfway (only evaluation errors and backup failures were injected).

## 12. The release for the first deployment: 26.05 now, 26.11 afterwards (decided by the owner, 2026-10-05)

[ADR 0016](0016-updates-deploys-and-checks.md) question 5. **Facts on 2026-10-05:** 26.05 gets security updates **until 2026-12-31**; **26.11 does not exist yet** (no `release-26.11` or `nixos-26.11` branch; the milestone is due **2026-11-30**), so **nothing of ours can be rehearsed on it**; the real machine still lacks its SSD and an Ethernet cable ([pending](../pending.md)), so the deployment will not be in days.

- **Proposal: deploy on 26.05, and move to 26.11 through the same pipeline** (a pin pull request in the private repository, the backups first, the kernel reboot) **after rehearsing it in the lab once the branch exists** (the version watch will say 26.05's lines are old; the restore drill and the deploy tests of this ADR are the rehearsal). The move happens **before 2026-12-31**, so the period on 26.05 is **at most about three months**, and the machine starts with the system that every test of phases 0 to 8 was run on.
- **Against, and why it does not win:** waiting for 26.11 (the end of November) delays the deployment for a release that cannot be tested yet and starts the machine on a release with no field time; deploying on 26.05 costs one extra major move shortly after, which the pipeline is built to do.
- **The owner agreed on 2026-10-05**: 26.05 first. If the real deployment slips past the end of November, the question is reopened (start on 26.11 directly, after the same rehearsal).

## Decisions for the owner

**Decided (2026-10-03 to 2026-10-05):** `system.autoUpgrade` every 10 minutes **on Monday to Saturday**; every protection of section 7; **two merges**; **the reboot allowed in a window of 06:00 to 07:00**; **Renovate on the server** with a machine user's token; **the TPM alone, no PIN** ([ADR 0005](0005-storage-layout-and-filesystem.md)); Nextcloud 33 and PostgreSQL 17 for now.

**Also decided on 2026-10-05:** 26.05 for the first deployment and 26.11 afterwards (section 12); the exclusion of Sunday from the deploy timer (section 9).

**Still the owner's to do, before the deployment:** the machine user and its token; the private repository from the template; the deploy key; the ruleset on the fresh public repository; the **firmware password and the Secure Boot setup mode**, the **SSD** (a 1 TB NVMe drive, on its way; the cable is not needed: [ADR 0019](0019-the-real-machine-network-and-hardware.md)), and **the first kernel update at the console** ([the runbook](../encryption-runbook.md)).

## Consequences

- `modules/renovate.nix`, off by default (`tidepool.renovate.enable`); `base.nix` sets `nix.settings.experimental-features`.
- `modules/deploy.nix`, off by default (`tidepool.deploy.enable`); the example host leaves it off (it needs the private flake's address). `.github/rulesets/main.json`, the `check` workflow, `renovate.json` and `private-repo-template/` (a copy-and-fill start for the private repository, with the pin's workflow) are in the repository.
- The sops file of the private repository gains a `deploy-key` secret.
- The `RebootPending` rule is in `versions/rules.yml`, with its unit test.
- **Closes** [ADR 0016](0016-updates-deploys-and-checks.md) questions 1 (the structure: a private flake importing the public one), 4 (the rollback point: the backups) and 6 (the server starts the deploy); question 2 (Renovate, which side), 3 (cadence: Monday) and 5 (26.05 or 26.11) remain.
