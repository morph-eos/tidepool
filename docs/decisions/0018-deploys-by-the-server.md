# 0018. Deploys: the server pulls what was merged, the backups run first, the private repository

- **Status:** proposed (2026-10-03), **built and measured in the lab**; the owner's choice of the pulling tool is open (recommendation: `system.autoUpgrade`); nothing is on the real server
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

**Recommendation: A.** It is the only one that is a maintained NixOS module **and** makes a failed deploy loud. comin's advantages (60-second polling, metrics) are not needed for a home server (10 minutes is enough), and the runner brings the most risk for no gain. **Open decision 1: A, B or C.**

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

## 7. What this does not do

- **It trusts the public repository's `main`**: whoever can merge there puts code on the server. Branch protection with the CI check required, and the owner as the only merger, are **open decision 4**.
- **It does not reboot.** A kernel or ZFS update waits for the owner; nothing says "a reboot is pending" yet.
- **The poll is not instant**: a merge is applied within the interval (10 minutes in the module) plus the build and the backups.
- **Not tried:** comin with the backups before the switch and its idle cost; a runner; the whole flow against GitHub; the real data's backup times; a deploy that fails the **build** halfway (only evaluation errors and backup failures were injected).

## Decisions for the owner

1. **The pulling tool:** `system.autoUpgrade` (recommended), comin, or a runner.
2. **The poll interval:** 10 minutes (the module's default), or longer.
3. **Renovate:** GitHub's app or on the server.
4. **Protection of the public `main`:** required CI check, the owner as the only merger.
5. **One merge or two:** a merge in the public repository deploys directly (built), or a pull request bumps the public input in the private repository first.
6. **A reboot policy** for a new kernel: by hand (built), or a window.

## Consequences

- `modules/deploy.nix`, off by default (`tidepool.deploy.enable`); the example host leaves it off (it needs the private flake's address).
- The sops file of the private repository gains a `deploy-key` secret.
- **Closes** [ADR 0016](0016-updates-deploys-and-checks.md) questions 1 (the structure: a private flake importing the public one), 4 (the rollback point: the backups) and 6 (the server starts the deploy); question 2 (Renovate, which side), 3 (cadence: Monday) and 5 (26.05 or 26.11) remain.
