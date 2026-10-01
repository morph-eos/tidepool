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
5. **Experiments, time-boxed.** Each candidate is tried in a throwaway VM (see `lab/`), on its own branch `exp/<phase>-<candidate>`.
   A time box (one evening, one weekend) is part of the experiment: "how long did it take to get working" is itself a result.
6. **Record the result.** What worked, what did not, what surprised me, measured numbers. Failures are results too.
7. **Decide, in an ADR.** One file in `docs/decisions/`, from the template: context, options, criteria, outcome, consequences.
8. **Integrate and freeze.** The winner is merged into `reengineering`; the phase closes with a tag (`v1-phase-N`). Losing branches are **kept**
   and tagged `exp-<phase>-<candidate>` (a hyphen: a tag and a branch cannot share a name) so the ADR can link to something that never moves.

## Rules

- **Nothing touches the real server before it has been rebuilt from scratch in a VM at least once.** The lab is the default, the server is the exception.
- **Every experiment ends with a way back**: a snapshot, a branch, or a script that undoes it.
- **Backups come before data.** Nothing holds real data until a restore has been rehearsed.
- **Measure, do not guess.** Numbers worth collecting: time from an empty disk to running services, time to restore, count of manual steps, idle RAM.
  v0 baseline: 9 manual steps in the rebuild order, never timed.
- **Secrets never enter the repository in clear text**, not even in experiment branches.
- **Clean over clever** ([principles](principles.md)): tools are used as documented, through maintained NixOS modules, with no glue scripts; any exception goes in [the register](exceptions.md).
- **Small steps, verified each time.** A step is done when its check passes, not when the command returns.

## What lives where

| Place | What |
|---|---|
| `reengineering` | the integrated result of the closed phases |
| `exp/<phase>-<candidate>` (branch), `exp-<phase>-<candidate>` (tag) | one candidate's experiment, kept after the decision |
| `docs/decisions/` | one ADR per decision, numbered |
| `docs/method.md` | this file |
| `docs/principles.md`, `docs/exceptions.md` | what a good answer looks like, and the register of exceptions |
| `lab/` | the tooling to create, snapshot and destroy the throwaway VMs |
| `~/lab/tidepool/` (outside the repo) | VM disks and base images, never committed |

## Phases

| # | Phase | Question it answers | Status |
|---|---|---|---|
| 0 | Lab | Can I build, break and rebuild a machine cheaply and repeatably? | **done**, [ADR 0001](decisions/0001-lab-on-qemu-vms.md) |
| 1 | Foundations | How is the host described as code, and where do secrets live? | host **decided** (NixOS, [ADR 0002](decisions/0002-host-as-code.md)); secrets **decided** on 2026-10-01 ([ADR 0003](decisions/0003-secrets.md): SOPS with age through sops-nix, confirmed by the owner; key in Proton Pass and on paper; variables in a private repository); the [G1 gate](gates/G1-live-usb.md) **passed** ([results](gates/G1-results.md): the desktop and sound work, and the GPU lists hardware decode and encode for H.264, HEVC, VP9 and AV1) |
| 2 | Backup | Can I restore, before there is anything to lose? | **decided** on 2026-10-01 and reviewed for coherence the same day (pgBackRest for the databases; Borg, two repositories, for the files; ZFS; PostgreSQL 17; offsite: Proton Drive tested first, Hetzner as the fallback): [ADR 0004](decisions/0004-backup.md), [0005](decisions/0005-storage-layout-and-filesystem.md), [0006](decisions/0006-postgresql-version-and-immich.md), [0007](decisions/0007-offsite-copy.md); provisional parts wait for the inventory [S1](gates/S1-storage-inventory.md), and nothing is built on the real server until a restore has been rehearsed |
| 3 | Edge | How does traffic reach the services, with which certificates? | **decided** on 2026-10-01: nginx with the NixOS ACME module ([ADR 0008](decisions/0008-edge.md)), plain WireGuard ([ADR 0009](decisions/0009-remote-access-vpn.md)), VM services private by default ([ADR 0010](decisions/0010-vm-service-exposure.md)), the DNS challenge by CNAME delegation from the DNS provider to the public acme-dns; nothing is built on the real server yet |
| 4 | Services | In what order, and how, does each service move over from v0? | **decided** on 2026-10-01 ([ADR 0011](decisions/0011-services.md)): native Nextcloud, Vaultwarden, Syncthing, smartd; Jellyfin 12.1 and Immich as pinned containers; WebDAV through nginx; Nextcloud as the single sign-on provider; nothing is built on the real server yet |
| 5 | Observability | How do I find out something broke without noticing by chance? | **decided** on 2026-10-01 ([ADR 0012](decisions/0012-observability.md)): Prometheus and Alertmanager with declared rules, email only through Brevo (decided), outside heartbeat on Healthchecks.io; nothing is built on the real server yet |
| 6 | Network and VMs | What is exposed, and how is the VM lab kept safe? | not started |
| 7 | Automation | How is "rebuild from scratch" proven on every change? | not started |

The list is a plan, not a promise: a phase can be split, merged or reordered when an experiment shows it should.
