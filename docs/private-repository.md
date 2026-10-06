# The private repository

The public repository (this one) is the whole system **except the values that identify one machine**. Those live in a second, **private** repository that you create from [`private-repo-template/`](../private-repo-template/) and that **imports this flake**. Why it is split, and how the server reads it: [ADR 0003](decisions/0003-secrets.md), [ADR 0018](decisions/0018-deploys-by-the-server.md) sections 2 and 4.

## What is in it

| File | What it is |
|---|---|
| `flake.nix` | eight lines: one input (`tidepool`, this repository) and one output, `nixosConfigurations.tidepool = tidepool.lib.mkHost ./host.nix`. |
| `flake.lock` | **pins the one revision of this repository that the server deploys.** Moving the pin is the deploy. |
| `host.nix` | one NixOS module with the machine's **values**: `tidepool.domain`, the admin's SSH key, the four disks by their stable `/dev/disk/by-id` paths, the WiFi block and LAN interface, the VPN peers, which optional parts are on (`nas`, `push`, `encryption`, `offsite.proton`, `deploy`, `renovate`), and where the deploy comes from. It is the only place where public options get private values. |
| `secrets.yaml` | every secret of the machine, **encrypted with sops to the machine's age key** (names in [`nixos/secrets/example.yaml`](../nixos/secrets/example.yaml)). Safe to commit: Nix never needs it in clear at evaluation, sops-nix decrypts it at activation into `/run/secrets`. |
| `.sops.yaml` | which age keys can read `secrets.yaml` (the machine's, and yours for editing). |
| `.github/workflows/bump-public.yml` | every day at 05:17 UTC, moves the pin to the newest `main` of this repository and **opens a pull request**. |
| `modules/` (optional) | your own NixOS modules for anything this repository does not have; imported from `host.nix`. Nothing of the public repository is edited ([the template's README](../private-repo-template/README.md#adding-your-own-modules-anything-the-public-repository-does-not-have)). |

Never in it: a copy of the public code, anything that is not a value or a secret.

## How a change reaches the machine

```
 you / Renovate ──PR──▶ public main ──(CI flake-check, signed squash)──┐
                                                                       ▼
 private repo: bump-public.yml opens "Deploy tidepool <rev>" ──merge──▶ private main (flake.lock moved)
                                                                       ▼
 server, every 10 min Mon–Sat: fetches the private repo by its read-only deploy key
   → runs every backup (pgBackRest, Borg) → if one fails, STOPS (nothing is activated)
   → nixos-rebuild switch → a new kernel? reboot between 06:00 and 07:00
```

1. A change is made in **this** repository by pull request. The ruleset requires the `flake-check` job and signed squash commits.
2. The workflow of the private repository **proposes** the new pin. **Merging that pull request is the deploy**: it is the second merge, the one that says "this machine takes it now" ([ADR 0018 section 8](decisions/0018-deploys-by-the-server.md)). Read the commit list in its description first.
3. The server looks every 10 minutes (Monday to Saturday), **backs up first**, then switches. A change to your own values is a commit in the private repository, by pull request, in the same way.

The server holds **one credential** for GitHub: the read-only deploy key of the private repository (secret `deploy-key`). It cannot write anywhere.

## Setting it up

The numbered steps are in [the template's README](../private-repo-template/README.md); the order of the day is in [the deployment runbook](deployment-runbook.md) (section 0). In short: copy the template to a new private repository; replace every `REPLACE-…` and `OWNER`; make the age key and write `.sops.yaml`; fill `secrets.yaml` and `deploy-key`; `nix flake lock`; check that `nix build .#nixosConfigurations.tidepool.config.system.build.toplevel` works; turn on the Actions setting for `bump-public.yml`.

## Working with it afterwards

- **Edit a secret:** `sops secrets.yaml`, commit by pull request; the machine takes it at the next deploy.
- **Add a value or an option:** in `host.nix`; the public options and their defaults are in [`nixos/modules/`](../nixos/modules/).
- **Add your own service:** a file under `modules/`, imported from `host.nix`; add its data path to the Borg job so that it is backed up.
- **Follow the public `main` directly** (one merge instead of two): set `tidepool.deploy.inputs.tidepool` in `host.nix` (the commented line there). The server then deploys whatever is merged in the public repository.
- **Roll back:** revert the pin (a pull request that restores the previous `flake.lock`), or at the console pick the previous generation in the boot menu.

## Keep safe

The **age key** (machine) and the Borg and pgBackRest keys: written down in Proton Pass **and on paper** ([the runbook](deployment-runbook.md) 0.2). Without the age key `secrets.yaml` cannot be read, and the repository is not enough to rebuild the machine.
