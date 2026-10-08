# Principles

The [method](method.md) says *how* decisions are made. These say what a good answer looks like. They come from the owner, and from what v0 taught (34 scripts that only its author could keep alive).

## P1. Clean over clever

**The system uses each tool the way the tool is meant to be used.** That means:

- **Configuration, not patches.** A tool is configured through its documented options. Nothing modifies its core, and nothing wraps it so that it behaves differently from how its documentation says it behaves.
- **A maintained NixOS module, not a hand-written service.** If a NixOS module exists for a tool, that is how it is deployed. If there is only a package, the cost of writing and keeping the service definition counts against the tool.
- **A container is an accepted way to run a tool that has no module**, if it is declared in the flake (`virtualisation.oci-containers`), the image is **pinned by digest**, its configuration lives in the flake and its state in a named volume that is backed up. The owner prefers containers where nothing native fits. The cost that counts is what an update means: a new digest to review, and a restore drill.
- **No scripts that compensate.** No pre/post hooks that change the flow of a tool (the `bpstart` kind of script that alters how a backup system runs), and no scripts that drive a tool through its API to make up for something it does not do.
- **No hybrids, and no manual steps in steady state.** Two tools doing one job half each, or a person who must remember to run something, are design faults, not compromises.

**Why.** Every custom piece is a thing that must be re-tested at each upgrade. A system built from documented features upgrades by changing a version and running the same checks; a system built from glue upgrades by rereading the glue.

**How it is applied.**

1. **It is a gate before it is a score.** In every decision, an option that needs custom glue is set aside unless nothing else meets a *must*. The ADR records, for each option, whether a module exists and how much glue it would need.
2. **Exceptions are written down** in [the exceptions register](exceptions.md): what the glue is, why there is no native way, who keeps it up to date, the test that runs at every upgrade, and how it is removed when a native way appears. An exception without an entry is a violation.
3. **It is measured.** Lines of custom script and number of exceptions are reported at the end of each phase. v0 is the baseline: 34 scripts in `nas-scripts/` plus the ones under `docker/` (in the tag `v0`).
4. **Upgrades are routine, and proved.** Updating the pinned inputs (`flake.lock`), rebuilding and running the checks must be the whole upgrade procedure. A restore drill is part of the checks (phase 7).

**What it does not forbid.** The lab tooling in `lab/` is scaffolding for experiments, not part of the running system, and is exempt, but is also kept small. A one-time, read-only human check (the gates) is not glue. Choosing a less featureful tool because it is clean is allowed, and expected.
