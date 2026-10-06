# Method: how the new system is built

The archive (`v0`) describes a server that grew by accident. The new one is built on purpose, one **phase** at a time, and every phase follows
the same loop. The point is not only the result: it is being able to explain, later, *why* each piece is what it is.

## The loop, for every phase

1. **Frame the problem.** One paragraph: what this phase must achieve, and which v0 lesson or open issue it answers.
2. **Requirements, from v0.** Split into *must* (the phase fails without it), *should* (clearly better with it) and *won't* (explicitly out of scope).
   v0 is the specification: its services, its data, and its incidents become acceptance criteria.
3. **Candidates.** Two or three real options, including "keep what v0 does" when it is a fair contender.
4. **Criteria, decided before testing.** A short weighted list (for example: rebuild time, moving parts, failure modes, fit with a shared media-center machine,
   how much I have to learn, how well it is documented). Writing them first keeps the winner from being chosen by the last thing I tried.
5. **Experiments, time-boxed.** Each candidate is tried in a throwaway VM (see `lab/`). A time box (one evening, one weekend) is part of the experiment:
   "how long did it take to get working" is itself a result.
6. **Record the result.** What worked, what did not, what surprised me, measured numbers. Failures are results too.
7. **Decide, in an ADR.** One file in `docs/decisions/`, from the template: context, options, criteria, outcome, consequences.
8. **Integrate.** The winner is merged into `reengineering`, and `reengineering` into `main`, which is what is published and deployed. The experiments themselves
   are not published: the decision record keeps what was measured, and the scripts worth keeping are in `lab/`.

## Rules

- **Nothing touches the real server before it has been rebuilt from scratch in a VM at least once.** The lab is the default, the server is the exception.
- **Every experiment ends with a way back**: a snapshot, a branch, or a script that undoes it.
- **Backups come before data.** Nothing holds real data until a restore has been rehearsed.
- **Measure, do not guess.** Numbers worth collecting: time from an empty disk to running services, time to restore, count of manual steps, idle RAM.
  v0 baseline: 9 manual steps in the rebuild order, never timed.
- **Secrets never enter the repository in clear text**, not even in an experiment.
- **Clean over clever** ([principles](principles.md)): tools are used as documented, through maintained NixOS modules, with no glue scripts; any exception goes in [the register](exceptions.md).
- **Small steps, verified each time.** A step is done when its check passes, not when the command returns.

## What lives where

| Place | What |
|---|---|
| `main` | what is published and what the server deploys; the archive of v0 is the tag `v0` |
| `reengineering` | where the phases are integrated, before they are merged into `main` |
| `docs/decisions/` | one ADR per decision, numbered |
| `docs/method.md` | this file |
| `docs/principles.md`, `docs/exceptions.md` | what a good answer looks like, and the register of exceptions |
| `lab/` | the tooling to create, snapshot and destroy the throwaway VMs |
| `~/lab/tidepool/` (outside the repo) | VM disks and base images, never committed |

## Phases

Each phase ends in one or more decision records. What was decided, as it stands:

| # | Phase | Question it answers | Decision |
|---|---|---|---|
| 0 | Lab | Can I build, break and rebuild a machine cheaply and repeatably? | throwaway QEMU/KVM VMs ([ADR 0001](decisions/0001-lab-on-qemu-vms.md)) |
| 1 | Foundations | How is the host described as code, and where do secrets live? | NixOS as a flake ([ADR 0002](decisions/0002-host-as-code.md)); sops-nix with age, the key kept off the machine, the values in a private repository ([ADR 0003](decisions/0003-secrets.md)) |
| 2 | Backup | Can I restore, before there is anything to lose? | pgBackRest for the databases; Borg, in two repositories, for the files; ZFS for the services; PostgreSQL 17; an offsite copy ([ADR 0004](decisions/0004-backup.md), [0005](decisions/0005-storage-layout-and-filesystem.md), [0006](decisions/0006-postgresql-version-and-immich.md), [0007](decisions/0007-offsite-copy.md)) |
| 3 | Edge | How does traffic reach the services, with which certificates? | nginx with the NixOS ACME module, the DNS challenge delegated by CNAME to a public acme-dns ([ADR 0008](decisions/0008-edge.md)); plain WireGuard ([ADR 0009](decisions/0009-remote-access-vpn.md)); VM services private by default ([ADR 0010](decisions/0010-vm-service-exposure.md)) |
| 4 | Services | In what order, and how, does each service move over from v0? | native Nextcloud, Vaultwarden, Syncthing, Samba and smartd; Jellyfin and Immich as containers pinned by digest; WebDAV through nginx; Nextcloud as the single sign-on provider ([ADR 0011](decisions/0011-services.md)) |
| 5 | Observability | How do I find out something broke without noticing by chance? | Prometheus and Alertmanager with declared rules, mail only, an outside heartbeat ([ADR 0012](decisions/0012-observability.md)) |
| 6 | Network and VMs | What is exposed, and how is the VM lab kept safe? | Incus with two pools and Podman instead of Docker, behind a publication gate ([ADR 0013](decisions/0013-vms-and-containers.md)) |
| 7 | Automation | How is "rebuild from scratch" proven on every change? | `nix flake check` on every change and the restore drill before a deployment ([ADR 0014](decisions/0014-automation-and-restore-drill.md), [runbook](restore-drill.md)); checks that restore backups ([ADR 0015](decisions/0015-backup-verification.md)) |
| 8 | Updates and deploys | How do new versions reach the machine safely, and where do the checks run? | the server pulls what was merged, the backups run first, Renovate on the server, two merges ([ADR 0016](decisions/0016-updates-deploys-and-checks.md), [0017](decisions/0017-version-watch-push-and-nas.md), [0018](decisions/0018-deploys-by-the-server.md)) |
| 9 | The real machine | What does the flake need to know about the real hardware, and how are its disks encrypted and its network brought up? | LUKS on every disk opened by the TPM, signed boot images, a hardware module and the WiFi ([ADR 0005](decisions/0005-storage-layout-and-filesystem.md), [0019](decisions/0019-the-real-machine-network-and-hardware.md), [runbook](encryption-runbook.md)); built and proved in the lab, deployment pending ([pending](pending.md)) |
