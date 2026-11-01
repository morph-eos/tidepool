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
- **The network, toward the machine itself:** a firewall rule for that user alone lets it use the loopback (and so the machine's own addresses) for the web (ports 80 and 443, that is nginx, which applies the names, the certificates and each service's own login) and the DNS, and nothing else. Measured on the real machine, before the rule, that user opened Syncthing's interface (`127.0.0.1:8384`, protected only by nginx and the VPN) with no login, and Prometheus's; after it, neither answers, while the public names and the web outside do. The rule names the user by number (`tidepool.desktop.uid`, 1002 by default), because the firewall rules are checked when the system is built, where the user does not exist yet.
- **The Nix daemon** is for root and the admin's group only.
- **Look:** the brand's wallpaper, dark style and accent colour, and a start page in the browser, all from `brand.json` ([ADR 0020](0020-brand-identity.md), update of 2026-11-01).
- **The bar at the bottom and the applications offered are declared** (`tidepool.desktop.dash`: the browser first, then Files; `tidepool.desktop.apps`: Settings, the image, video and document viewers, the calculator). GNOME lists every desktop entry of the system (35 of them on the real machine: disk and log tools, a manual, the Syncthing page...); a service hides, for this user only, every entry that is not offered, with an entry of the same name in its own folder. The admin and the system keep theirs; an application added later is hidden until it is named.
- **Language:** `tidepool.desktop.language` (`it_IT.UTF-8`, say) sets the language of the session's interface, GNOME and the browser, for this user only, the way Settings does it (the user's entry of AccountsService, which the login manager reads for the automatic login too). The machine's own language, and so its logs and messages, stays what `tidepool.locale.language` says (English by default: they are read and searched).
- **Software:** GNOME, Firefox. The terminal applications are left out of the session's menus.

## What it changes in what [ADR 0005](0005-storage-layout-and-filesystem.md) and the [encryption runbook](../encryption-runbook.md) say

Those pages said that a casual thief who switches the machine on gets nothing, because **no local login exists**. With the TPM unlocking the disks by itself, the machine now also **boots into a logged-in session of the unprivileged user**. Whoever is at the keyboard has a browser and can start a shell as that user. What stands between that and the data is: the services' files are owned by their users and not readable by others, the secrets are readable by root only, the databases and the other services listen on the machine or the VPN and ask for their own passwords, the user is in no group, and there is no `sudo`.

**This is a convenience with a stated price, not a lock.** A local user is more attack surface than none: a flaw in the kernel or in a setuid program could be a way up, and a service that listens on a Unix socket is protected only by that socket's file mode. (The services' network ports are closed to that user by the rule above.) The decision is to accept that, for a machine that is also a TV box, with the rights cut as far as they go. It is a switch: `tidepool.desktop.enable = false` returns to a console with no session.

## What it does not do

- It does not make the session a kiosk: a local user can start other programs (a shell too, from Firefox's file dialogs or its other features). The limit is what that user may do, not what it may start.
- The checks made on the real machine (2026-11-01), as that user: no `sudo`, no group; polkit refuses switching off, restarting, suspending, units and disks (asked with `pkcheck`, never run); the files of the services, the backups, the secrets and the signing keys are not readable (only the names of some folders are visible); the databases refuse it; Syncthing's and Prometheus's interfaces are closed to it by the rule. Not yet checked: that the sound and the hardware video decode work in the browser, and what the screen shows. The lab has no screen. The list of what to look at again after a change: it cannot `sudo`; it cannot list or read the data of the services, the NAS share, the backups or the secrets; it cannot connect to the databases; it cannot power off, restart or suspend from the menu; the sound and the hardware video decode work in the browser.

## To decide after a few weeks of use

Keep it as it is, or move to a kiosk (one application, no desktop) if the family only ever uses a browser or a media client.
