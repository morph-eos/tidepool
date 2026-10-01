# Register of exceptions to P1 (clean over clever)

Each entry is custom glue that is in the running system because no native way exists. An empty register is the goal; at the end of phase 2 it holds one entry.

| # | What it is | Why there is no native way | Who keeps it up to date | Test run at every upgrade | How it goes away |
|---|---|---|---|---|---|
| 1 | **pgBackRest with a local repository** ([ADR 0006](decisions/0006-postgresql-version-and-immich.md)): the two backup-job units of the module run as `postgres` (`User` and `Group` overridden with `mkForce`), `users.users.pgbackrest.homeMode = "770"`, `ReadWritePaths` of `postgresql.service` for the repository path, and the cipher passphrase in a file under pgBackRest's own `conf.d` (a sops-nix template in production; this last one is a documented pgBackRest feature, not glue) | the module is built for a repository on **another host**; pgBackRest creates directories 0750 whatever the umask, so the user that archives (`postgres`, inside a sandboxed unit) and the user of the jobs (`pgbackrest`) cannot both write; and the module refuses `cipher-pass` as an option (it would land in the world-readable Nix store) | the owner and the assistant; the lines sit in the host flake | after every nixpkgs update: the weekly job runs, `pgbackrest check` passes, and a point-in-time restore of a lab database succeeds (the lab bake-off script, and the restore drill of phase 7) | the module learns to run a local repository (or the repository moves to another host over SFTP); then the overrides are deleted |

**Planned and not yet in the system** (the register is edited in the commit that adds the glue): a small declared step that registers the **OpenID clients in Nextcloud** after its setup ([ADR 0011](decisions/0011-services.md)); and
 (to be entered in the commit that adds it): a small container with the official Proton Drive CLI and a repository of our own, if Proton Drive is adopted as the offsite ([ADR 0007](decisions/0007-offsite-copy.md)).

Rules: an entry is added **in the same commit** as the glue; a phase does not close with an entry that has no test; when a native way appears the entry is removed and the glue deleted.
