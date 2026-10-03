# 0003. Where secrets live

- **Status:** accepted (2026-10-01, confirmed by the owner in words: "vada per sops + age"): SOPS with age through sops-nix; key in Proton Pass and on paper; variables in a separate private repository
- **Date:** 2026-09-29
- **Phase:** 1, Foundations

## Context

In v0 every secret sits in `docker/.env` in clear text, and that file is copied into the local Borg repository, which is not encrypted: whoever can read the data disk has
every secret. The Borg passphrase, the Proton session and the OIDC client secrets each live somewhere different, and the rotation procedure is written in the README rather
than in a script.

## Requirements

- **Must:** no secret in clear text in the repository or in any backup that is not itself encrypted; a machine can be rebuilt from the repository plus **one** key kept outside it;
  a secret can be delivered to the host with the right owner and mode (H09 of [the host specification](../specs/host.md)).
- **Should:** readable diffs (which secret changed, not only that something did); rotation is one command; works from the tool chosen in [ADR 0002](0002-host-as-code.md);
  the key can be recovered if the workstation is lost.
- **Won't:** a secrets server (Vault and similar): too many moving parts for one household machine.

## Options considered

| Option | Branch / tag | Tested how | Result in one line |
|---|---|---|---|
| A. SOPS + age (files encrypted in the repository) | `exp/secrets-sops-age`, tag `exp-secrets-sops-age`; the NixOS side is in `exp/host-nixos` (sops-nix) | scenario script, Ansible delivery, NixOS delivery | passes everything; works with both host candidates |
| B. git-crypt | none (script only) | scenario script | passes T1-T3; cannot remove a recipient |
| C. pass (GPG password store) | none (script only) | scenario script | passes T1-T3, T5; one file per secret, file names visible |
| D. Ansible Vault | none (script only) | scenario script | passes T1-T3, T5; one shared password, only useful with Ansible |
| E. agenix | not run | read only | age-based like A, but NixOS only and without structured files: not a contender on its own |

## Criteria

**Gate: [P1, clean over clever](../principles.md).** An option that needs custom glue is set aside unless nothing else meets a *must*.


1. **Safety of the failure modes:** what happens if the key is lost, if the repository leaks, if a secret is committed by mistake.
2. **Rebuild fit:** one key from outside, delivered without typing passwords in the middle of the run.
3. **Readable diffs and one-command rotation.**
4. **Best practice:** what people who run this seriously use today.
5. **Moving parts:** tools to install and keep up to date.

## Results

`lab/secrets-bakeoff.sh` runs the same scenario for A-D in a temporary directory with a throwaway GPG home; secrets are random canary strings, so a leak is found by grep.
It starts with a **negative control**: a repository with the secrets committed in clear text, where T1 and T3 must fail. A first version had every candidate green, and a test
that cannot fail proves nothing, so the control is now part of every run (exit 99 if it does not fail).

| Test | A. SOPS + age | B. git-crypt | C. pass | D. Ansible Vault |
|---|---|---|---|---|
| T1 no canary in any commit | pass | pass | pass | pass |
| T2 fresh clone + only the key restores everything | pass | pass | pass | pass |
| T3 without the key: nothing | pass | pass | pass | pass |
| T4 what a reader of the repo sees | names of the secrets, not values; one changed value = one changed line | one opaque binary file; a change rewrites the whole file | one file per secret, **file names visible** | one opaque text blob; a change rewrites the whole file |
| T5 replace the key | `sops updatekeys`: new key reads, old does not | can **add** a recipient, cannot remove one (the repository key stays) | `pass init <new key>` re-encrypts everything | `ansible-vault rekey` |

Beyond the scenario:

| | A. SOPS + age | B. git-crypt | C. pass | D. Ansible Vault |
|---|---|---|---|---|
| Installed without root | yes, two static binaries (sops, age) | yes, one binary, but it needs GPG | yes, a shell script, but it needs GPG | yes, but only inside Ansible |
| Key material | one small age key file; several recipients possible (workstation, paper, hardware key) | GPG keyring | GPG keyring | one shared password |
| Works with Ansible | **tested**: `community.sops` lookup, 24 of 24 checks, second run 0 changes, value on the host matches (by hash) | as files, through `git-crypt unlock` | needs a lookup plugin | native |
| Works with NixOS | **tested**: sops-nix, the secret rendered into a `root`-only file at activation and never in the Nix store | not natural | not natural | not applicable |
| Structured files (yaml, dotenv) | yes, encrypts values and keeps the keys readable | no, whole file | no | no, whole file |

### Things that hold for every option

- **Rotating the key does not protect history.** Anyone who has an old key and an old commit can still read the old secrets. Rotating a key limits *future* exposure; a leaked
  *secret* has to be changed at its source (the database, the SMTP relay) and the value re-encrypted.
- **Metadata:** with SOPS the names of the secrets are public, with pass the file names are. Nothing here is sensitive in a name like `SMTP_PASSWORD`.
- **Accidents:** encryption does nothing about a secret committed in clear by mistake. A scanner such as `gitleaks` as a pre-commit hook is a separate control, not tested here.
- **Bootstrapping:** the key that decrypts everything must not live only in a service that this repository rebuilds. If the age key sat only in the self-hosted Vaultwarden, restoring
  from an empty server would be circular. Field advice says the same: what the bootstrap depends on must be independent of what it bootstraps.

### Effect of P1 (2026-09-30)

| Option | Native on NixOS? | Glue needed |
|---|---|---|
| sops-nix (A) | yes, a NixOS module with `sops.secrets` and `sops.templates` | none: the env files the Compose stack needs are rendered by the module itself |
| agenix (E/B) | yes, a NixOS module | none, but no templates: each env file is one secret |
| Proton Pass CLI (C, tested only for "does the binary start") | **no**: a binary run through a fetch step | a script or service to call `pass-cli inject`, a personal access token to store on the machine, renew (sessions last two hours) and rotate, and a network dependency at rebuild time |
| Ansible Vault | not applicable once the host is NixOS | not applicable |

Candidate C fails the gate as it stands: its integration is exactly the kind of custom fetch-and-inject step the principle excludes, plus a token lifecycle to maintain. The test that was planned (an account login and a scoped token)
is therefore **not needed to decide**; it can still be run if the owner wants to know how it behaves. **Proton Pass stays useful for the human part**: keeping a copy of the age private key outside the server, which is a one-time manual act, not steady-state glue.

## Decision (2026-10-01)

**Correction.** An earlier edit of this file on 2026-10-01 wrote this ADR as *accepted*. It was not: the owner answered the quiz with "15a (only if I am forced to use sops and have no better choices)", which is a condition, not a confirmation, and was never asked to confirm SOPS by itself.
The earlier "confirm sops-nix, or revisit agenix?" question was postponed by the owner ("we will talk about secrets later"). This ADR is therefore **proposed**, with a recommendation.

**Recommendation: A, SOPS with age, through sops-nix**, for these reasons, which the owner can weigh against the alternatives:
- it passed every test of the scenario, **with both host candidates** (Ansible through `community.sops`, NixOS through sops-nix), and is the only option that renders structured files (the `.env` files) **through a NixOS module, with no script** assembling them;
- git-crypt cannot remove a recipient; pass and Ansible Vault need a GPG keyring or only work with Ansible;
- **agenix**, which the owner asked to try, is age-based too and as native on NixOS, but has **no templates** (each env file becomes one secret) and is NixOS-only: a fair alternative, slightly less convenient here;
- **Proton Pass as a machine mechanism** was tried only as far as "does the binary start" and set aside on paper: it needs a personal access token on the machine, refreshed (sessions last two hours), and a step that fetches secrets at boot, which is glue; it stays useful for **keeping the human copy** of the age key.

**The owner's answers so far, valid under either recommendation** (they do not depend on which tool is chosen):
- **Custody of the age key** (or whatever key the chosen tool uses): in **Proton Pass**, with a **printed copy** if possible; Proton Pass alone is the accepted minimum. The same custody for the offsite backup passphrase ([ADR 0007](0007-offsite-copy.md)).
- **Non-secret variables** (domain, addresses, names, ports): a **separate private GitHub repository**, with the public one showing example values only. The deployment was to run **from the workstation** ([ADR 0002](0002-host-as-code.md)), so the server would never need a credential for the private repository. **Revised 2026-10-03** (see the update below): the workstation has no Nix, so a deploy is built on the server ([ADR 0016](0016-updates-deploys-and-checks.md)).

**Confirmed by the owner, in a separate message after the correction above: SOPS with age, through sops-nix.** The secrets of the backups ([ADR 0007](0007-offsite-copy.md)) and of the databases ([ADR 0006](0006-postgresql-version-and-immich.md)) use it. Still to do: create the private repository for the variables, and write the age key down in Proton Pass and on paper.

## Update 2026-10-03: the public repository will become public

The owner's answer to [ADR 0016](0016-updates-deploys-and-checks.md) question 11: **the repository will be made public** once everything is on the server and the security problems of the old scripts are fixed. Effects on this ADR:

- **The server needs no credential for the public repository** (a plain `git clone` or a flake input over HTTPS). The **private** repository (the values and the secrets file) is still the only thing that needs a way onto the server: copied by the owner at each deploy, or fetched with a **read-only deploy key** if that is chosen later ([ADR 0016](0016-updates-deploys-and-checks.md), design B).
- The encrypted secrets file of the **public** repository holds only the **lab and example** values; the real one is in the private repository.
- **Before it goes public** the history was cleaned of the one commit that held the owner's domain and every commit was scanned ([ADR 0017 section 6](0017-version-watch-push-and-nas.md)); publishing from a **fresh repository** is the safest way, because GitHub may keep old commits reachable by hash.

## Consequences

- Secrets live in `secrets/*.yaml` in the repository, encrypted; `.sops.yaml` lists the recipients. The private key never enters the repository.
- `docker/.env` stops being a file to copy by hand: it is generated from the encrypted source, and the unencrypted local Borg repository no longer holds the only copy of every secret.
- Adding a person or a machine as a recipient is `sops updatekeys`; removing one is the same command, and the secrets it saw still have to be rotated at their source.
- Revisit if the host decision (ADR 0002) leaves Ansible and NixOS both out, or if the age key custody cannot be solved.
