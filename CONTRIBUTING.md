# Contributing

Tidepool is a home server written for one person and published so that others can read it, copy from it and use it as a starting point. Pull requests and issues are welcome; the maintainer reads them when they can. How the work is done is in [docs/working-on-it.md](docs/working-on-it.md); the short version:

## Before you start

- **Nothing private, anywhere.** No real domain, IP address, serial number, account name, token, key or password: not in a file, a commit message, a branch name, a pull request or an issue. Use placeholders (`example.invalid`, `OWNER`, `REPLACE-...`). A leaked secret is rotated, not deleted: the history keeps it.
- Read the decision records ([docs/decisions/](docs/decisions/)) of the part you touch. A change that goes against one needs a new record that says why.

## A change

1. A **branch** from `main`, never a push to `main` (the [ruleset](.github/rulesets/main.json) refuses it, for the maintainer too).
2. Run what covers your change: `nix flake check` for any module; [`lab/gate.sh`](lab/gate.sh) when it touches what the gate covers (boot, storage, services, the lab VMs; see [lab/README.md](lab/README.md)). Say in the pull request what you ran and what you saw. What you could not run, say so.
3. Open a **pull request**. The CI job `flake-check` must pass and the branch be up to date with `main`; the merge is a **squash**, signed by GitHub.
4. Documents are code here: a link that breaks or a page that is not indexed fails the CI (`.github/scripts/check-docs.py`).

## Style

Write like the file you are in: its comment density, its names, its idiom. A comment says why, not what. A claim in a document is either measured (say where) or marked as not tried.

## Issues

A bug, a question or an idea: use the templates. For anything that is a security problem, follow [SECURITY.md](SECURITY.md) instead.

By contributing you agree that your work is under the repository's [license](LICENSE).
