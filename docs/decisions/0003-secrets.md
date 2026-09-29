# 0003. Where secrets live

- **Status:** proposed (experiments not run yet)
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

| Option | Branch / tag | Time box | Result in one line |
|---|---|---|---|
| A. SOPS + age (files encrypted in the repository) | `exp/secrets-sops-age` | one evening | |
| B. git-crypt | `exp/secrets-git-crypt` | shared with A | |
| C. pass (GPG password store) | `exp/secrets-pass` | shared with A | |
| D. Ansible Vault | `exp/secrets-ansible-vault` | only if ADR 0002 picks Ansible | |

## Criteria

1. **Safety of the failure modes:** what happens if the key is lost, if the repository leaks, if a secret is committed by mistake.
2. **Rebuild fit:** one key from outside, delivered without typing passwords in the middle of the run.
3. **Readable diffs and one-command rotation.**
4. **Best practice:** what people who run this seriously use today.
5. **Moving parts:** tools to install and keep up to date.

## Results

_To fill after the experiments._

## Decision

_Pending._

## Consequences

_Pending._
