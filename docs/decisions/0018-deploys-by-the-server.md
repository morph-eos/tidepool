# 0018. Deploys: the server pulls what was merged, the backups run first, the private repository

- **Status:** accepted. Built and measured in the lab, including the reboot with the encrypted layout and the TPM; the flow against GitHub itself was not run when this was written
- **Date:** 2026-10-03
- **Phase:** 8, Updates and automation (follow-up of [ADR 0016](0016-updates-deploys-and-checks.md) and [0017](0017-version-watch-push-and-nas.md))

## Context

What I decided:

- The deploy is started by the server, when a change is merged. Not by me at a keyboard, and not by a GitHub job pushing to the server.
- The public repository is public; the private one, which holds the values, is not. How the server reads it had to be worked out.
- No scheduled (hourly) snapshots. Instead, every backup method runs before an update.
- Nextcloud 33 and PostgreSQL 17 stay for now (the rest is decided later, [ADR 0017 section 8](0017-version-watch-push-and-nas.md)).

I was unsure between comin and a runner on the server.

## 1. Who applies the change

| Option | Tried | Result |
|---|---|---|
| A. `system.autoUpgrade` (a NixOS module: a timer runs `nixos-rebuild switch` against the flake) | yes, here (`lab/experiments/deploy-u16.sh` to `u18`) | works. In nixpkgs, no extra flake input; a failure is a failed unit (`UnitFailed` mails, [ADR 0015](0015-backup-verification.md)); idle cost about 1 s of CPU per tick |
| B. comin (pulls, polls every 60 s) | [ADR 0016](0016-updates-deploys-and-checks.md) (a deploy took 69 s); not tried with the backups before the switch | a separate flake, not in nixpkgs 26.05; an evaluation error is only an `info` line in its log and no unit fails, so the alert stays quiet; it serves 9 metrics |
| C. A GitHub runner on the server (`services.github-runners`) | no: it needs a GitHub registration | GitHub advises self-hosted runners only with private repositories, because a pull request to a public one can run code on the machine ([secure use](https://docs.github.com/en/actions/reference/security/secure-use)); a deploy job there is root on the server; it adds nothing the pull does not already do |
| D. Running `nixos-rebuild` by hand after a merge | ADR 0016 | the baseline; against the decision above |

I chose A. It is the only one that is a maintained NixOS module and makes a failed deploy loud. comin's advantages (60-second polling, metrics) are not needed for a home server, where 10 minutes is enough, and the runner brings the most risk for no gain.

## 2. The design

```
public repository (modules, flake.lock, CI)         private repository (values, encrypted secrets, a flake that imports the public one)
   |  pull request: Renovate + `nix flake check`         |  a change of values is pushed
   |  merged  ----------------------------------------+  |
                                                      v  v
   the SERVER, every 10 minutes (system.autoUpgrade):
     1. fetch the private repository over ssh with a read-only DEPLOY KEY (GitHub's host key pinned)
     2. replace the public input by its newest commit (--override-input), unless the private lock pins it
     3. evaluate; if the system is the one that runs: stop (a tick costs about 1 s)
     4. build it
     5. BEFORE activating (system.preSwitchChecks): Borg of everything, Borg offsite, a pgBackRest diff; if one fails, STOP
     6. switch
   a failed step = a failed unit = a mail in 5 minutes
```

- A merge is the approval: nothing reaches the server that was not merged to `main`. A change of values is a push to the private repository's `main`.
- A major upgrade of Nextcloud or PostgreSQL is a deploy like any other. It is deliberate because it is a merge, and the backups before it are the only way back (section 5).

## 3. Measured in the lab host

Two local bare repositories stand in for the two GitHub repositories.

| Test | Result |
|---|---|
| Idle ticks (nothing changed, a tick every minute) | about 1.0 s of CPU, 4 s of wall time, 25 MB; the generation does not change; no backup runs (the check compares the incoming system with the running one) |
| A merge in the public repository | live 61 s and 81 s later (a one-minute timer in the lab) |
| The backups run before the switch | the Borg archive and the pgBackRest diff precede the activation |
| A backup that fails (the Borg repository made to disappear) | the change is not activated, `nixos-upgrade` fails, the `UnitFailed` mail arrived 390 s after the merge; when the repository came back the next tick applied the change after 71 s |
| A commit that does not evaluate | the unit fails with the syntax error in the journal, the running system is untouched, and the fixing commit was applied 54 s later |
| `--update-input` against `--override-input` | the same behaviour, but `--update-input` prints a deprecation warning on every tick; the module uses `--override-input` |
| The deploy key over ssh (a key that is allowed only `git-shell`) | the flake is fetched; a shell command or reading another file is refused; the key revoked gives `Permission denied (publickey)`; a changed host key is refused |
| GitHub itself (`lab/experiments/deploy-u18.sh`) | the key is a root-only sops secret, ssh uses it only for github.com, GitHub's ed25519 host key is pinned (the one published at `api.github.com/meta`); a real connection reached GitHub and was refused only because the lab key is not registered; a wrong pinned key is refused |

A defect I introduced, found by the test and fixed: the first version of the pre-switch check called `readlink` by its bare name. The check script runs with an almost empty PATH, the command was not found, the condition read as false, and the change was activated without its backups, in silence. It is now written with the full path of every command and with `set -eu`, so a check that cannot run stops the switch. The test that found it compares the Borg archive time with the activation time; a deploy that "worked" proved nothing.

A test mistake, also recorded: unmounting the large disk did not make the backup fail, because systemd mounts it again for `RequiresMountsFor`; the failure had to be made by removing the repository.

## 4. The private repository: how the server reads it

The server needs the private repository to build, so it must hold a credential for it. The aim is the smallest one.

| Way | Result |
|---|---|
| A. A deploy key (an ssh key registered on that one repository, read-only by default, no expiry; [GitHub docs](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys)) | built and tried. Generated on the workstation, encrypted into the private repository's sops file (`deploy-key`), delivered by sops-nix at activation as a root-only file; GitHub's host key pinned in the configuration. Whoever steals it can read a repository that holds no secret in clear. It is revoked in GitHub's settings and rotated by editing one secret |
| B. A fine-grained access token (`nix.settings.access-tokens`) | not built: it expires, so someone must renew it, and a lapse means no deploys |
| C. A bare repository on the server, pushed to over the VPN | not tried: no GitHub credential at all, but the private repository then lives only on the server and the workstation, with no third copy and no pull requests on the values |
| D. The values in the public repository, encrypted | not possible: Nix needs the values in clear when it evaluates (the domain is used in expressions); sops decrypts at activation, not at evaluation |
| E. Copying the values at each deploy | against the decision that the server starts the deploy |

Bootstrap, in order: create the private repository; generate the deploy key on the workstation; encrypt its private half into the private sops file; add its public half to the private repository as a read-only deploy key; install the machine from the workstation's clone (`nixos-install --flake`, the age key at hand); from then on the server fetches by itself. Rotation: a new key into the sops file, the new public half on GitHub, deploy, remove the old one.

## 5. Backups before an update, and no snapshots

The rule is built: `system.preSwitchChecks` runs Borg of everything, Borg offsite and a pgBackRest differential backup before a change that differs from the running system, and stops the switch if any fails. What follows from it:

- The way back from a stateful upgrade is a restore, not a rollback. NixOS rolls the configuration back but not Nextcloud's or PostgreSQL's data ([ADR 0016](0016-updates-deploys-and-checks.md): Nextcloud refuses a downgrade). With a ZFS snapshot that would take seconds (50 ms to take, 4 to 8 s to roll back, measured there); with a backup it takes the restore drill's time ([ADR 0014](0014-automation-and-restore-drill.md)). A one-off snapshot just before a deploy would cost almost nothing and I did not adopt it; it can be added in one line to the same check.
- A deploy waits for the backups. Borg's jobs wait up to 12 hours for a lock ([ADR 0015](0015-backup-verification.md)), so a deploy that arrives during the Sunday checks waits for them.
- Every changing deploy pays for the backups, even a trivial one: minutes in the lab, more with real data. That is the price of the rule, and I accept it.

## 6. What is written for GitHub (not run there)

- `.github/workflows/check.yml`: `nix flake check` on every pull request and push to `main`, with the two actions pinned by commit; both hosts build and the version-watch rules run their unit test.
- `renovate.json`: Monday morning, a grouped pull request for the container pins (`image = "repo:tag@sha256:..."`), `flake.lock` maintenance, a major never merged without a person, the Actions pinned by commit. Tried locally (`renovate --platform=local` in the lab host): the config validates, and it found all four container pins and the `nixpkgs` input and planned the branch `renovate/container-updates`.

## 7. Protecting the public `main`

`.github/rulesets/main.json` is a GitHub ruleset for the default branch, imported once the public repository exists (`gh api -X POST repos/OWNER/REPO/rulesets --input .github/rulesets/main.json`). What each rule stops:

| Rule | Stops |
|---|---|
| a pull request is required, 0 approvals (a sole maintainer cannot approve their own pull request, so a required approval would force a bypass), stale approvals dismissed on a new push, threads resolved | a direct push to `main`: every change is a pull request that the CI has seen |
| the `flake-check` job must pass, on a branch up to date with `main` | a change that does not build, or breaks the version-watch rules, reaching the server |
| squash merges only (linear history) | merge commits that hide a change; and, because GitHub signs the squash commit it creates, it satisfies the next rule for every author, bots included |
| signed commits required | an unsigned commit pushed by a stolen token |
| no force push, no deletion of `main` | rewriting or removing what the server may already have deployed |
| no bypass actor, the admin role included | nobody can push to `main` directly or merge around a failing job, me included |

Settings next to it: Actions run with a read-only token by default (the workflow also says `permissions: contents: read`); fork pull requests need approval before their workflows run; secret scanning with push protection; private vulnerability reporting; passkeys and two-factor on the account.

I revised it once: the first version let the admin role bypass through a pull request and asked for 1 approval. In practice that meant I merged around the rule every time, so it protected nothing my account did not already hold. Now the rule is the same for everyone. What this gives up, plainly: there is no second pair of eyes by rule, and a token with the write role (the Renovate machine user, section 10) can merge its own pull request once the CI is green. It does not here because Renovate has no `automerge` and a major waits on the dashboard, but that is configuration, not enforcement. If the bot's pull requests ever become many, the approval goes back and the admin bypass stays for me only.

Limits, plainly:

1. The GitHub account is the root of trust: an attacker who takes it over can change the ruleset, so the account's own security matters most.
2. Rulesets are enforced only on public repositories on the free plan, which is why this lives on the public one.
3. The ruleset guards the deploy: every commit that reaches `main` and changes the host's system is on the server within 10 minutes.

Applied: the ruleset is imported and active, and a direct push to `main` is refused ("Changes must be made through a pull request", "Required status check `flake-check` is expected").

## 8. One merge or two

One merge: the server follows the public repository's `main` (`tidepool.deploy.inputs`), so merging a pull request in the public repository is the deploy. Two merges: the private repository's `flake.lock` pins one public revision, the server deploys exactly that, and a second pull request, in the private repository, moves the pin (`private-repo-template/.github/workflows/bump-public.yml` opens it daily; merging it is the deploy). Both are built; the module's default (`inputs = {}`) is the second.

| | One merge | Two merges |
|---|---|---|
| Approvals | one (the public pull request) | two: the public one, then the pin's |
| Who can put code on the server | anyone who can write the public `main` (the ruleset is the only gate) | also needs write access to the private repository, which no outsider and no Renovate token has |
| A record of what is deployed | none in git (the server takes the newest each time) | the private repository's history: one commit per deployed public revision |
| Going back | revert in the public repository (affects the example and the lab as well) | revert the pin's commit in the private repository |
| When it deploys | within 10 minutes of the merge | at a moment chosen by merging the pin |
| What it costs | nothing | one more click per deploy; a daily workflow |
| Rebuilding from the private repository alone | uses a stale lock unless overridden | exact, and the public lock's `nixpkgs` comes with it |

A commit that changes only documentation in the public repository did not change the system and ran no backup (the tick found the same system), so merges that touch only `docs/`, the lab or the examples do not reach the server's backups or switch in either design.

I chose two merges. The second gate is on a repository that no bot can write, the pin gives an audit trail and a clean way back, and it lets me pick the moment. The price is one click. `inputs` is the switch: leave it empty (two merges) or set it to the public URL (one).

Tried in the lab with the template made into a private repository (`lab/experiments/private-repo-u24.sh`, on the real public layout, the flake in `nixos/` read as `git+file://...?dir=nixos`): the lock pins the public revision and the public lock's `nixpkgs`; the real host builds (225 s, a 6.2 GiB closure); the disko script touches neither of the two large disks; the pin moves with `nix flake update tidepool`, as the workflow does; a docs-only public change leaves the system identical and a change to a module changes it. Not tried on GitHub: the workflow itself, which needs a repository and the setting that lets Actions open pull requests.

## 9. A new kernel: the reboot

How NixOS decides: after a switch it compares `/run/booted-system` (kernel, initrd, kernel modules) with the new system. `tidepool.deploy.reboot.allow` turns the automatic reboot on and `window` limits it to a time of day.

Measured in the lab host (kernel 6.18 to 6.12, a real change):

| | Result |
|---|---|
| Reboot off (the default) | the new kernel is activated but not running; the machine kept the old one for as long as it was left |
| The warning | `RebootPending` returns the series while the activated and running kernels differ and is empty after the reboot; it fires after a day (unit-tested: silent at 12 h, firing at 30 h) |
| Reboot on | the deploy ran the backups, switched, rebooted by itself; ssh was down for about 20 s; afterwards the new kernel ran, no unit had failed, and every service answered |
| A detail | the module re-schedules the reboot (`shutdown -r +1`) at every tick; with a 10-minute timer it does not matter |

Other things to weigh: kernel point releases come about weekly, so allowing the reboot means a reboot about weekly, a minute each; a reboot interrupts a running Borg job (it resumes at the next hour); without a reboot the fixes of the new kernel do not apply, which is what `RebootPending` is for.

I allow the reboot, in a window of 06:00 to 07:00 (set in the private template; the module's default stays off). That depends on the TPM unlocking the disks by itself, the weaker option I chose in [ADR 0005](0005-storage-layout-and-filesystem.md). In the lab, a kernel change followed by a reboot opened the disks by itself with PCR 7 unchanged. The conditions are written down: the TPM sealed to PCR 7 only, not to the kernel image, no PIN at boot, and the first kernel update rehearsed at the console (`nixos-rebuild boot`, then a reboot) before the machine is left alone. If the machine does not come back, the heartbeat stops and Healthchecks.io mails within minutes ([ADR 0012](0012-observability.md)): a stuck boot is noticed, not silent.

What the window test showed (`lab/experiments/deploy-u20-window.sh`, found by a first attempt that rebooted outside the window):

- With the reboot allowed, a deploy that changes the kernel is only installed: the script runs `nixos-rebuild boot` (the new system becomes the boot default and is not activated), then compares the kernels. Equal, it runs `switch`; different and outside the window, it prints "Outside of configured reboot window, skipping." and stops, successfully; different and inside, it schedules the reboot.
- Outside the window the machine kept running the old kernel; a second merge while the reboot was pending was not activated either; in the window the first tick scheduled the reboot, with 20 s of downtime, and after it the held merge was live.
- Consequences: everything merged while a reboot is pending waits for the reboot, not only the kernel. A change of the window itself is read from the script that is active, so when it arrives with a kernel change the old window decides: change the window in a deploy of its own. `RebootPending` compares the activated system with the running kernel, so it does not cover this mode; a reboot that never comes is not signalled (at most a day), only a machine that does not return. The pre-switch backups run when the new system is installed, up to a day before the reboot, and the hourly Borg jobs cover the hours in between. A unit that fails after the switch makes `nixos-upgrade` fail too, so a failure anywhere in a deploy is loud.

With the encrypted layout and the TPM (`lab/experiments/deploy-u22-encrypted.sh`: the lab host on UEFI, Secure Boot on, every volume sealed to PCR 7, an emulated TPM), the same sequence holds:

| Step | Result |
|---|---|
| A kernel change is merged; the server installs it outside the window | the Borg archives rose before it, the new boot image was installed and signed (`sbctl verify`), the machine kept running the old kernel |
| A second merge arrives while the reboot is pending | held |
| The window opens | the machine rebooted by itself on the first tick in the window, back in 27 s, no passphrase asked, the new kernel running, the held merge live, Secure Boot still on, PCR 7 unchanged, ZFS online, no failed unit |

The rebuild from blank with the same layout also passes ([restore-drill.md B2](../restore-drill.md): 14 checks, 0 failed units; the signing keys come back from Borg, so the firmware's old keys still accept the new boot images and the old TPM seal of the mid-size disk still opens it). Still untried at the time: real firmware and a real TPM.

The window and the Sunday checks. The borgmatic checks start on Sunday at 04:30 and verify every byte of every archive of a large repository, which on real data may last hours. A reboot at 06:00 would cut them, cleanly but without an alert. So the deploy timer runs Monday to Saturday (`interval = "Mon..Sat *:0/10"`, in the private template): no tick on Sunday, so no reboot on Sunday. A change merged on a Saturday evening or a Sunday is installed on Monday at 00:00 and the reboot comes at 06:00 that day. If the Sunday check turns out to be short, the exclusion can go.

## 10. Renovate: GitHub's app or the server

Renovate does two things that are different in kind: the container pins and the Actions' commits (it only needs the registries and GitHub), and refreshing `flake.lock` (it must run Nix).

| | GitHub's app (Mend's hosted Renovate) | On the server (`services.renovate`) |
|---|---|---|
| Identity | its own `renovate[bot]`, not an admin | a token: a fine-grained token acts as its owner |
| A secret on the server | none | yes, with write access to pull requests and contents of the public repository, kept in sops; it expires, so a lapse must be noticed |
| Do the protections hold? | partly: the bot opens pull requests and the rule holds, but no approval is required | only with a separate machine account; with a personal token the bot acts as that person and could merge its own pull request |
| `flake.lock` | probably not: the stock Renovate container has no Nix | yes: the module takes `runtimePackages` where `nix` and `git` go |
| Cost on the server | nothing | 924 MB of memory at the peak, 38 s of CPU in 67 s for one local lookup run; weekly |
| Who sees the repository | Mend, for the public repository only (never install it on the private one: it would see the values) | nobody outside |
| When it fails | silently (a dashboard issue) | a failed unit: the `UnitFailed` mail |

I chose Renovate on the server (`modules/renovate.nix`, off by default, `tidepool.renovate.enable`; the private template turns it on). The hosted app's doubts (no Nix, the identity) are avoided, and the price is a token on the server. So the token belongs to a machine user: a second free GitHub account with the write role (not admin), fine-grained to the public repository only (contents and pull requests), kept in sops as `renovate-token`. It expires, and the day it does the unit fails.

Measured in the lab host (`lab/experiments/renovate-u19.sh`; the token is a dummy, GitHub refuses it):

| | Result |
|---|---|
| The module | the configuration is validated at build time by Renovate's own validator; a weekly timer (Monday 04:30); a dynamic user; `nix` and `git` in its PATH; the token reaches the unit as a systemd credential (in no environment variable and not in the unit file) |
| A lapsed or wrong token | the unit fails in 5 s with "github.com token 401 unauthorized"; the `UnitFailed` mail names it (about 6 minutes) |
| Nix under that kind of user (a dynamic user, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `NoNewPrivileges`) | `nix flake update` works, 25 s |
| `nix.settings.experimental-features` | was not set anywhere in the flake, so `nix flake update` as that user would fail; it is now in `base.nix` |

Not tried: the pull requests themselves (they need the public repository and the machine user), and whether Renovate's `lockFileMaintenance` branch is produced (the local platform does not make it, with or without Nix at hand). The first real `flake.lock` pull request will show it.

## 11. What this does not do

- It trusts the public repository's `main`: whoever can merge there puts code on the server. The ruleset of section 7 is what stands in front of it.
- It does not reboot by default, and the TPM case on real hardware is untried (section 9).
- The poll is not instant: a merge is applied within the interval (10 minutes in the module) plus the build and the backups.
- Not tried: comin with the backups before the switch and its idle cost; a runner; the whole flow against GitHub; backup times with real data; a deploy that fails the build halfway (only evaluation errors and backup failures were injected).

## 12. The release for the first deployment: 26.05 now, 26.11 afterwards

At the time of this decision 26.05 gets security updates until 2026-12-31 and 26.11 does not exist yet (the milestone is due 2026-11-30), so nothing of ours can be rehearsed on it.

I chose to deploy on 26.05 and move to 26.11 through the same pipeline (a pin pull request in the private repository, the backups first, the kernel reboot) after rehearsing it in the lab once the branch exists. The version watch will say 26.05's lines are old, and the restore drill and the deploy tests of this ADR are the rehearsal. The move happens before 2026-12-31, so the period on 26.05 is at most about three months, and the machine starts with the system that every test of phases 0 to 8 was run on.

Against, and why it does not win: waiting for 26.11 delays the deployment for a release that cannot be tested yet and starts the machine on a release with no field time, while deploying on 26.05 costs one extra major move shortly after, which the pipeline is built to do. If the real deployment slips past the end of November, I reopen the question and start on 26.11 directly, after the same rehearsal.

## Decisions

`system.autoUpgrade` every 10 minutes from Monday to Saturday; every protection of section 7; two merges; the reboot allowed in a window of 06:00 to 07:00; Renovate on the server with a machine user's token; the TPM alone, no PIN ([ADR 0005](0005-storage-layout-and-filesystem.md)); Nextcloud 33 and PostgreSQL 17 for now; 26.05 first, then 26.11.

## Consequences

- `modules/renovate.nix`, off by default (`tidepool.renovate.enable`); `base.nix` sets `nix.settings.experimental-features`.
- `modules/deploy.nix`, off by default (`tidepool.deploy.enable`); the example host leaves it off (it needs the private flake's address). `.github/rulesets/main.json`, the `check` workflow, `renovate.json` and `private-repo-template/` (a copy-and-fill start for the private repository, with the pin's workflow) are in the repository.
- The sops file of the private repository gains a `deploy-key` secret.
- The `RebootPending` rule is in `versions/rules.yml`, with its unit test.
- This closes [ADR 0016](0016-updates-deploys-and-checks.md)'s open points: the structure (a private flake importing the public one), the rollback point (the backups), who starts the deploy (the server), Renovate's side, the cadence and the release.
