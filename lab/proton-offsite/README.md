# lab/proton-offsite/: the test of Proton Drive as the offsite destination ([ADR 0007](../../docs/decisions/0007-offsite-copy.md))

What was run, on 2026-10-06, to try the official Proton Drive CLI against the criteria fixed in the ADR. The results are in the ADR. None of this is part of the system: it is the evidence, and what a production unit would be made of.

| File | What it is |
|---|---|
| `Containerfile` | the image: Ubuntu with `dbus`, `gnome-keyring` and `libsecret`, because the CLI refuses to start without a Secret Service ("libsecret not available") |
| `run.sh` | inside the container: a headless keyring is unlocked with a password, then the CLI runs. The session lives in the keyring file on a volume |
| `pd.sh` | one CLI command in a fresh container (`PTHOME` the volume, `PTBIN` the CLI binary: the official one, pinned by its published SHA-512) |
| `sync-offsite.sh` | the whole custom component: upload what is new or changed (a new revision, identical content is skipped), move to the trash what the repository no longer has, exit non-zero on any failure |

**To repeat it**, in a lab VM with Podman: build the image, run the login once (`pd.sh auth login` prints an address to open **on any device**, and waits), then point `sync-offsite.sh` at a test Borg repository and a test folder of the Drive. The login is the owner's, so it cannot be scripted; **`auth logout` only removes the local credentials: revoke the session in the Proton account's security settings when a test is over.** Never use `filesystem empty-trash`: the trash is the whole account's.
