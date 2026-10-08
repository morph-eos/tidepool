# The documents

**Picking the project up? Read [working-on-it.md](working-on-it.md) first** (the repositories, the rules, where each kind of thing is written), then [pending.md](pending.md) (everything that is still to be done in this repository: it is the only such list) and [the deployment runbook](deployment-runbook.md) (the order of the day).

## By what you want to do

| I want to... | Read |
|---|---|
| know what is left to do | [pending.md](pending.md) |
| do the first deployment | [deployment-runbook.md](deployment-runbook.md), with [migration-from-v0.md](migration-from-v0.md), [encryption-runbook.md](encryption-runbook.md), [restore-drill.md](restore-drill.md) |
| know when something runs, and what an alert means | [schedule.md](schedule.md), [decisions/0012](decisions/0012-observability.md) |
| see the names of the services and the DNS they need | [names.md](names.md) |
| know how big things get | [capacity.md](capacity.md) |
| set up a private repository for another machine | [private-repository.md](private-repository.md), [../private-repo-template/](../private-repo-template/README.md) |
| open the machine's private tools from one page | [decisions/0021](decisions/0021-admin-page.md), `admin.<domain>` on the VPN |
| change the look (name, colours, logo) | [decisions/0020](decisions/0020-brand-identity.md), [../nixos/brand/README.md](../nixos/brand/README.md) |
| test a change before it goes to `main` | [../lab/README.md](../lab/README.md) (`lab/gate.sh`) |
| understand why a choice was made | the decision records below |
| see the rules the choices follow, and the glue that breaks them | [principles.md](principles.md), [exceptions.md](exceptions.md), [method.md](method.md) |
| look at v0, the old server | the tag `v0` (`git show v0:README.md`) |

## The decision records

One record per decision, with what was measured. A later change is an **Update** section at the end of the record: the history is not rewritten.

| # | Decision |
|---|---|
| [0001](decisions/0001-lab-on-qemu-vms.md) | the lab: throwaway QEMU/KVM virtual machines on the workstation |
| [0002](decisions/0002-host-as-code.md) | the host is a NixOS flake (Ansible was tried and is kept privately) |
| [0003](decisions/0003-secrets.md) | secrets: sops with age, through sops-nix |
| [0004](decisions/0004-backup.md) | backups: pgBackRest for the databases, two Borg repositories for the files |
| [0005](decisions/0005-storage-layout-and-filesystem.md) | disks: ZFS on the SSD, ext4 on the large disks, LUKS opened by the TPM |
| [0006](decisions/0006-postgresql-version-and-immich.md) | PostgreSQL 17 as a native service; Immich in pinned containers |
| [0007](decisions/0007-offsite-copy.md) | the offsite copy: Borg to Proton Drive, Hetzner as the fallback |
| [0008](decisions/0008-edge.md) | the edge: nginx, certificates by the DNS challenge delegated by CNAME, the names |
| [0009](decisions/0009-remote-access-vpn.md) | remote access: plain WireGuard |
| [0010](decisions/0010-vm-service-exposure.md) | the services of virtual machines: private unless the flake says otherwise |
| [0011](decisions/0011-services.md) | how each service runs; the single sign-on |
| [0012](decisions/0012-observability.md) | observability: Prometheus, Alertmanager, mail, heartbeats |
| [0013](decisions/0013-vms-and-containers.md) | virtual machines and containers: Incus and Podman |
| [0014](decisions/0014-automation-and-restore-drill.md) | the rebuild-from-nothing and restore drill |
| [0015](decisions/0015-backup-verification.md) | checks that prove a backup can be restored |
| [0016](decisions/0016-updates-deploys-and-checks.md) | updates, deploys, and where the checks run |
| [0017](decisions/0017-version-watch-push-and-nas.md) | the version watch, push notifications, the NAS |
| [0018](decisions/0018-deploys-by-the-server.md) | deploys: the server pulls what was merged; the private repository; the protection of `main` |
| [0019](decisions/0019-the-real-machine-network-and-hardware.md) | the real machine: hardware, WiFi until the cable, the 1 TB SSD |
| [0020](decisions/0020-brand-identity.md) | one name, palette and logo for every service; the single sign-on |
| [0021](decisions/0021-admin-page.md) | one admin page, on the VPN, for the private tools (a trial) |

## Reference material
- [gates/](gates/): the questions asked of the real machine before the design (the storage inventory and its results).
- [specs/](specs/): what the host must satisfy, checked by `lab/experiments/check-host.sh`.
- [evidence/](evidence/) and [brand/](brand/): measurements and images the records point to.
