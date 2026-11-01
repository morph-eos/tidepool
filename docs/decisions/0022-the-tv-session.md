# 0022. The TV session: a desktop that starts by itself, for a user that can do almost nothing

- **Status:** accepted by the owner (2026-11-01); built (`nixos/modules/desktop.nix`, off by default, on in the owner's private repository); **to be proved on the real machine**
- **Date:** 2026-11-01
- **Phase:** 9, Deployment preparation (found on the first boot of the real machine)

## The question

[ADR 0002](0002-host-as-code.md) lists, among the requirements that must hold, "keep working with a desktop session (the server is also a media center)", and names "GNOME on the TV". Its gate G1 (the GPU and the desktop) passed on 2026-09-30 with the installer's live image. After the first boot of the installed machine the console showed a text login and nothing else: **no module of the flake started a graphical session.** The requirement had been checked once, with an image that is not ours, and never written down as configuration. The lab has no screen and no GPU, so nothing there could have noticed.

## What was decided

The owner asked for **GNOME, started by itself** (no login screen), with one condition: the user that the session runs as must have **almost no rights**, enough to open a web browser and do generic things, and nothing that could cause a problem to a service.

- **A user of its own** (`tidepool.desktop.user`, `tv` by default): a group of its own (not `users`, the group of the NAS share's user), **no extra group** (no `wheel`, no container or VM group, no `render`/`video`: the screen and the sound come from the login manager's seat), **no password** (the automatic login needs none, and password login over ssh is off), **no ssh key**.
- **The services are not that user.** They keep their own users; the admin keeps an ssh key and has **no local login**. The TV session is a third thing and the only account with a local session.
- **Polkit** refuses that user the actions that a local session gets by default and that matter to a server: switching off, restarting or suspending the machine, managing units, the network, the disks, the hostname, the clock. Sleep and hibernation are off for the machine; the screen never locks (a locked session without a password would be a dead screen) and the lock-screen, user switching and the run dialog are off in a locked dconf profile.
- **The Nix daemon** is for root and the admin's group only.
- **Software:** GNOME, Firefox. The terminal applications are left out of the session's menus.

## What it changes in what [ADR 0005](0005-storage-layout-and-filesystem.md) and the [encryption runbook](../encryption-runbook.md) say

Those pages said that a casual thief who switches the machine on gets nothing, because **no local login exists**. With the TPM unlocking the disks by itself, the machine now also **boots into a logged-in session of the unprivileged user**. Whoever is at the keyboard has a browser and can start a shell as that user. What stands between that and the data is: the services' files are owned by their users and not readable by others, the secrets are readable by root only, the databases and the other services listen on the machine or the VPN and ask for their own passwords, the user is in no group, and there is no `sudo`.

**This is a convenience with a stated price, not a lock.** A local user is more attack surface than none: a flaw in the kernel or in a setuid program could be a way up, and any service that listens on the machine without a password of its own can be reached. The decision is to accept that, for a machine that is also a TV box, with the rights cut as far as they go. It is a switch: `tidepool.desktop.enable = false` returns to a console with no session.

## What it does not do

- It does not make the session a kiosk: a local user can start other programs (a shell too, from Firefox's file dialogs or its other features). The limit is what that user may do, not what it may start.
- It is not proved on the real machine yet, nor in the lab (no screen). The checks to make there, as that user: it cannot `sudo`; it cannot list or read the data of the services, the NAS share, the backups or the secrets; it cannot connect to the databases; it cannot power off, restart or suspend from the menu; the sound and the hardware video decode work in the browser.

## To decide after a few weeks of use

Keep it as it is, or move to a kiosk (one application, no desktop) if the family only ever uses a browser or a media client.
