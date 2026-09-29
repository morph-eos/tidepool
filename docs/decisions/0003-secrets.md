# 0003. Where secrets live

- **Status:** proposed (experiments run; recommendation below, waiting for the owner's answer on key custody)
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

## Decision

**Recommended: A, SOPS with age.** It is the only option that is at once safe to lose the workstation (with the key kept elsewhere), readable in diffs, easy to rotate, installed as two static
binaries, and **tested with both host candidates** (Ansible through `community.sops`, NixOS through sops-nix). B cannot remove a recipient, C and D depend on tools that
only one of the two hosts uses well, and E is NixOS-only.

**Still open, and it is the owner's call:** where the age private key lives so that it is independent of this server, and how it is backed up (see the questions in the session notes:
an off-server password manager, a printed copy, a second recipient on a USB stick). Until then the status stays *proposed*.

## Consequences

- Secrets live in `secrets/*.yaml` in the repository, encrypted; `.sops.yaml` lists the recipients. The private key never enters the repository.
- `docker/.env` stops being a file to copy by hand: it is generated from the encrypted source, and the unencrypted local Borg repository no longer holds the only copy of every secret.
- Adding a person or a machine as a recipient is `sops updatekeys`; removing one is the same command, and the secrets it saw still have to be rotated at their source.
- Revisit if the host decision (ADR 0002) leaves Ansible and NixOS both out, or if the age key custody cannot be solved.
