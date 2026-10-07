# Working on it: the repositories, the rules, where things are written

For whoever picks the project up with no memory of how it was done (the owner, a collaborator, an assistant in a new session). Start here, then follow the links. Nothing private is in this page: the private side is described by what it is for, not by what it holds.

## Four places, four jobs

| Place | Job | Published? |
|---|---|---|
| **This repository** (the public one) | the whole system as code and the reasons for it: the flake, the lab, the decision records, the runbooks | yes, `main` is what a machine deploys |
| **The private repository of one machine** (made from [the template](../private-repo-template/); how it fits: [private-repository.md](private-repository.md)) | that machine's values, its encrypted secrets, its extra modules, its notes for the cutover; the server reads it by a deploy key | a private remote, read-only deploy key |
| **A local-only folder of private tooling** | the privacy audit and the list of strings that must never be published, the real machine's inventory, the real domain's DNS notes, the hooks that enforce it. Kept out of the machine's repository because a flake is copied whole into the machine's Nix store, and these have no business there | never |
| **An archive of the experiments** (a bare repository, local) | the branches and tags of the experiments that the decision records summarize, and the obsolete tools of the clean-up | never |

A fifth thing is not in any repository: the lab (`lab/vm.sh`) keeps its disks, images and test keys in a folder outside them (`~/lab/tidepool`, [lab/README.md](../lab/README.md)).

## Branches and merging
- `main` is protected by [a ruleset](../.github/rulesets/main.json): a pull request, the `flake-check` job passing, squash merges only, signed commits (GitHub signs the squash), no force push. The owner merges with the admin bypass **through a pull request**, never by pushing.
- `reengineering` is kept equal to `main` (the development branch of the earlier phases).
- A change: a branch, a pull request (the description ends with the generation line when an assistant wrote it), CI green, squash merge, then `reengineering` moved to `main`. CI quirk: a push of more than three refs at once creates no workflow run.
- `git reset --hard` discards staged work: commit or stash first.

## The rule that matters most
**No private information in this repository, in any file, message, branch or pull request.** That means the real domain, addresses, serial numbers, account names, tokens, the names of services that only the owner runs. Placeholders (`example.invalid`, `OWNER`, `REPLACE-...`) stand in for them. It is enforced locally by three git hooks (before a commit, in its message, before a push: the staged changes and the whole history against the private list, and a secret scanner against a baseline); the hooks and how to install them are in the local-only folder. A hook blocking a commit is correct until proven otherwise: reword, do not bypass.

## Where each kind of thing is written
| What | Where |
|---|---|
| Why a decision was made, what was measured | `docs/decisions/NNNN-*.md`; a later change is an "Update" section at the end, the history is not rewritten |
| What the system is, one decision per row | [the README](../README.md) |
| What is left, and who it waits for | [pending.md](pending.md) |
| The order of the day of the move from v0 | [deployment-runbook.md](deployment-runbook.md), with [the migration](migration-from-v0.md), [the encryption stages](encryption-runbook.md), [the restore drill](restore-drill.md) |
| Custom glue that breaks "clean over clever" | [exceptions.md](exceptions.md): an entry in the same commit as the glue |
| Times and cadences of everything automatic | [schedule.md](schedule.md) |
| Names of the services, and the DNS they need | [names.md](names.md) |
| How big things get | [capacity.md](capacity.md) |
| The method and the principles | [method.md](method.md), [principles.md](principles.md) |
| How to prove a change | `lab/*.sh` (each ADR names its script); `lab/vm.sh` makes the VMs |

## Picking up after losing the thread
1. Read [pending.md](pending.md) (what is left) and [the runbook](deployment-runbook.md) (the order of the day).
2. Check the state: `git log --oneline -20` here; the private repository's `tools/check.sh` lists what is still a placeholder.
3. Change things the way the rule says: lab first, a record of what was measured, the docs in the same commit.
