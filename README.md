# tidepool — a home server, re-engineered as code

**tidepool** is a family home server: photos, media, a personal cloud, a password manager, file sync, backups and a small VM lab. It used to be one Ubuntu machine,
34 shell scripts and a Docker Compose file (**v0**, archived in the tag `v0`). This repository is its **re-engineering**: the whole host described as a
**NixOS flake**, built one decided phase at a time, and **proved in throwaway virtual machines** before anything touches the real machine.

> **Status.** Everything here has been built and tested **in the lab**. **Nothing is deployed to the real machine yet.** What the lab cannot show (firmware and TPM,
> a real radio, the GPU, real certificates, mail, timings on the real data) is listed in [docs/pending.md](docs/pending.md).

## What is where

| Where | What |
|---|---|
| branch `main` | what is published and what the server deploys: the integrated result of the closed phases. Once the repository is public it is protected by [a ruleset](.github/rulesets/main.json) |
| branch `reengineering` | where the phases are developed; merged into `main` when a phase closes |
| tag `v0` | the archive of v0: 19 snapshots reconstructed from backups, anonymized. Its README is [docs/v0-README.md](docs/v0-README.md) |
| [nixos/](nixos/) | the flake: modules, the lab hosts, an example of the real host, the lab's secrets |
| [docs/](docs/) | [the method](docs/method.md), [the principles](docs/principles.md), one [decision record](docs/decisions/) per decision, runbooks (the order of the first deployment is in [the deployment runbook](docs/deployment-runbook.md)), [the capacity of the disks](docs/capacity.md), [what is still open](docs/pending.md) |
| [lab/](lab/) | the tooling and the test scripts: QEMU/KVM VMs, the restore drill, the encrypted-layout test, the deploy tests, the migration rehearsal |
| [private-repo-template/](private-repo-template/) ([how it works](docs/private-repository.md)) | the template of the **private** repository that holds one machine's values and secrets and imports this one |
| `docker/`, `nas-scripts/` | v0's scripts and compose file, kept as reference and as the specification of the data to migrate. They are anonymized and not maintained |

## What the system is

One decision per row, each with its measurements in the linked record. The rule behind all of them is **clean over clever**
([principles](docs/principles.md)): a tool is used the way its documentation says, through a maintained NixOS module, with no glue scripts; every exception is in
[a register](docs/exceptions.md).

| Area | Decision | Record |
|---|---|---|
| Host | NixOS 26.05 flake; one lab host and one real host built from the same modules | [0002](docs/decisions/0002-host-as-code.md) |
| Secrets | sops-nix with age; the repository holds only encrypted files | [0003](docs/decisions/0003-secrets.md) |
| Storage and boot | ZFS for the services, ext4 for the big disks; LUKS on every disk, opened by the TPM (PCR 7 only), signed boot images (Secure Boot with the owner's keys) | [0005](docs/decisions/0005-storage-layout-and-filesystem.md), [runbook](docs/encryption-runbook.md) |
| Databases and Immich | PostgreSQL 17 as a native service; Immich in containers pinned by digest | [0006](docs/decisions/0006-postgresql-version-and-immich.md) |
| Backups | pgBackRest for the databases; Borg, two repositories, for the files; an offsite copy; checks that restore | [0004](docs/decisions/0004-backup.md), [0007](docs/decisions/0007-offsite-copy.md), [0015](docs/decisions/0015-backup-verification.md) |
| Edge | nginx through the NixOS module, certificates from the NixOS ACME module with the challenge delegated by CNAME; [the names](docs/names.md) of the services | [0008](docs/decisions/0008-edge.md) |
| Remote access | plain WireGuard; a VM service is private unless the flake says otherwise | [0009](docs/decisions/0009-remote-access-vpn.md), [0010](docs/decisions/0010-vm-service-exposure.md) |
| Services | native Nextcloud, Vaultwarden, Syncthing and Samba; Jellyfin and Immich as pinned containers (Podman) | [0011](docs/decisions/0011-services.md) |
| Observability | Prometheus and Alertmanager with declared rules, mail only, a heartbeat to an outside watcher | [0012](docs/decisions/0012-observability.md) |
| VMs | Incus, with two pools | [0013](docs/decisions/0013-vms-and-containers.md) |
| Proof | the host is rebuilt from an empty disk and the data restored, on demand: the restore drill | [0014](docs/decisions/0014-automation-and-restore-drill.md), [runbook](docs/restore-drill.md) |
| Updates and deploys | a version watch, Renovate on the server, the server pulls what was merged, the backups run first | [0016](docs/decisions/0016-updates-deploys-and-checks.md), [0017](docs/decisions/0017-version-watch-push-and-nas.md), [0018](docs/decisions/0018-deploys-by-the-server.md) |
| The real machine | its hardware module, WiFi until the cable, the new SSD | [0019](docs/decisions/0019-the-real-machine-network-and-hardware.md) |

## How a deploy works

This repository is public and holds **no value that belongs to one machine**. The machine's values (domain, disks, VPN peers, keys) and its encrypted secrets
live in a **private repository** made from [the template](private-repo-template/), which **imports this flake** and pins one revision of it in its `flake.lock`.
A change here reaches the server in two merges: a bot opens a pull request in the private repository that moves the pin, and merging it is the deploy.

The server runs `system.autoUpgrade` every ten minutes from Monday to Saturday, runs the backups before it switches, and reboots by itself, in a one-hour window,
only after a new kernel. The private repository can add modules of its own, which join the public host without replacing anything
([how](private-repo-template/README.md), [proof](lab/private-modules-u26.sh)). The details and the decisions are in [ADR 0018](docs/decisions/0018-deploys-by-the-server.md).

## How it is proved

Every phase follows [the same loop](docs/method.md): frame the problem, write the criteria first, try the candidates in throwaway VMs with a time box,
record the measurements, decide in a record, freeze. In the lab, with the data of a replica of v0:

- `nix flake check` builds the lab host and the example real host and checks the version-watch rules (it also runs in CI);
- **the restore drill** installs the host on an empty VM, seeds data, destroys the disks, rebuilds from the flake and restores, then checks the data, the databases and the backups;
- **the encrypted layout** (LUKS, an emulated TPM, signed boot images, a kernel update) is tried on a UEFI VM with Secure Boot;
- **the deploy chain** (private repository, pin bump, backups before the switch, the reboot window) and **the WiFi** (a virtual radio) have their own scripts;
- **the move from v0** is rehearsed on a replica running v0's exact versions: [docs/migration-from-v0.md](docs/migration-from-v0.md).

The lab's times are lab times (nested VMs, a slow link): they say what changes, not how long the real machine will take.

The experiments behind each decision (the candidates that were tried and dropped) are not published: the decision record keeps what was measured, and the scripts worth keeping are in [lab/](lab/).

## Try it

You need a Linux workstation with QEMU/KVM, `ssh` and Python 3; nothing is installed with root and nothing leaves `~/lab/tidepool/`.

```bash
(cd nixos && nix flake check)                     # the checks (needs Nix with flakes)
lab/vm.sh create host-t --blank --cpus 4 --mem 8192 --disk 40 --data-disk 20 --extra-disk 30 --extra-disk 15
TIDEPOOL_HOST=lab TIDEPOOL_LAYOUT=disko lab/nixos-install.sh host-t     # install the lab host from the flake
lab/restore-drill.sh all                                                # seed, disaster, rebuild, restore, verify: ends in DRILL RESULT
```

[lab/README.md](lab/README.md) describes the tooling and [the restore-drill runbook](docs/restore-drill.md) the proof, step by step.

## What is not done

- **It is not deployed.** The first deployment needs the owner's chores on the real machine ([docs/pending.md](docs/pending.md)): the firmware and Secure Boot setup, the disks, the private repository and its tokens, the first kernel update at the console.
- **Only the real machine can answer** the open questions listed there: the TPM and firmware, the radio, the GPU containers, real certificates and mail, and the timings on the real data.
- **The old scripts are an archive.** `docker/` and `nas-scripts/` are anonymized (addresses are documentation addresses) and were not re-tested after that.

## License

MIT, see [LICENSE](LICENSE). The scripts in `docker/` and `nas-scripts/` are an unmaintained archive of v0, with its security problems, and come with no warranty.
