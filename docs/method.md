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
- **Small steps, verified each time.** A step is done when its check passes, not when the command returns.

## What lives where

| Place | What |
|---|---|
| `reengineering` | the integrated result of the closed phases |
| `exp/<phase>-<candidate>` (branch), `exp-<phase>-<candidate>` (tag) | one candidate's experiment, kept after the decision |
| `docs/decisions/` | one ADR per decision, numbered |
| `docs/method.md` | this file |
| `lab/` | the tooling to create, snapshot and destroy the throwaway VMs |
| `~/lab/tidepool/` (outside the repo) | VM disks and base images, never committed |

## Phases

| # | Phase | Question it answers |
|---|---|---|
| 0 | Lab | Can I build, break and rebuild a machine cheaply and repeatably? |
| 1 | Foundations | How is the host described as code, and where do secrets live? |
| 2 | Backup | Can I restore, before there is anything to lose? |
| 3 | Edge | How does traffic reach the services, with which certificates? |
| 4 | Services | In what order, and how, does each service move over from v0? |
| 5 | Observability | How do I find out something broke without noticing by chance? |
| 6 | Network and VMs | What is exposed, and how is the VM lab kept safe? |
| 7 | Automation | How is "rebuild from scratch" proven on every change? |

The list is a plan, not a promise: a phase can be split, merged or reordered when an experiment shows it should.
