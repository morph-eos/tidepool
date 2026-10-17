# Security policy

## Reporting a vulnerability

Please **do not open a public issue** for a security problem. Use GitHub's private report instead: the repository's *Security* tab, then *Report a vulnerability*. Only the maintainer sees it.

Say what you found, where (file and line, or the module and option), how to reproduce it, and what it lets someone do. A minimal NixOS configuration or a lab VM transcript helps. Do not paste real secrets, domains or addresses: placeholders are enough.

This is a one-person project, so there is no response time promised; a report gets a first answer as soon as the maintainer can read it, and a fix goes out as a normal pull request once it is ready, with the credit you ask for.

## What is in scope

- The NixOS modules, the installer and lab scripts, the CI workflow and the repository's own settings (`.github/`).
- Defaults that leave a service reachable, unauthenticated or unencrypted when the documents say otherwise.
- A way for the repository or its history to carry a secret or a private value.

Out of scope: a weakness in an upstream program (report it there; a pinned version we should move is in scope), and a configuration someone changed away from the defaults.

## Supported versions

Only `main`. The machine this was written for pulls `main`; there are no release branches.
