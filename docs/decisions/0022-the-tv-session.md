# 0022. The TV session: a desktop that starts by itself, for a user that can do almost nothing

- **Status:** accepted; built (`nixos/modules/desktop.nix`, off by default); to be proved on real hardware
- **Date:** 2026-11-01
- **Phase:** 9, Deployment preparation

## The question

[ADR 0002](0002-host-as-code.md) lists, among the requirements that must hold, "keep working with a desktop session (the server is also a media center)", and names "GNOME on the TV". Its gate G1 (the GPU and the desktop) passed with the installer's live image. After the first boot of the installed machine the console showed a text login and nothing else: no module of the flake started a graphical session. The requirement had been checked once, with an image that is not ours, and never written down as configuration. The lab has no screen and no GPU, so nothing there could have noticed.

## Decision

I want GNOME, started by itself (no login screen), with one condition: the user that the session runs as must have almost no rights, enough to open a web browser and do generic things, and nothing that could cause a problem to a service.

- A user of its own (`tidepool.desktop.user`, `tv` by default): a group of its own (not `users`, the group of the NAS share's user), no extra group (no `wheel`, no container or VM group, no `render` or `video`: the screen and the sound come from the login manager's seat), no password (the automatic login needs none, and password login over ssh is off), no ssh key.
- The services are not that user. They keep their own users; the admin keeps an ssh key and has no local login. The TV session is a third thing and the only account with a local session.
- Polkit refuses that user the actions that a local session gets by default and that matter to a server: switching off, restarting or suspending the machine, managing units, the network, the disks, the hostname, the clock. Sleep and hibernation are off for the machine; the screen never locks (a locked session without a password would be a dead screen), and the lock screen, user switching and the run dialog are off in a locked dconf profile.
- The network, toward the machine itself: a firewall rule for that user alone lets it use the loopback (and so the machine's own addresses) for the web (ports 80 and 443, that is nginx, which applies the names, the certificates and each service's own login) and the DNS, and nothing else. Before the rule, that user opened Syncthing's interface (`127.0.0.1:8384`, protected only by nginx and the VPN) with no login, and Prometheus's; after it, neither answers, while the public names and the web outside do. The rule names the user by number (`tidepool.desktop.uid`, 1002 by default), because the firewall rules are checked when the system is built, where the user does not exist yet.
- The files on disk: what the session may not see is closed by the owner of the file and its mode, not by hope. Nextcloud's, WebDAV's, Syncthing's and Vaultwarden's trees were already so. Immich's tree (the photos) and Jellyfin's (its database holds password hashes and API keys) are `0700` root, which is enough because their containers run as root: with the earlier `0755` that user could list and read both. Folders left over from a migration on a data disk (old dumps, an old home directory) can hold the same kind of thing, and should be closed too, wherever they come from.
- The Nix daemon is for root and the admin's group only.
- Look: the brand's wallpaper, dark style and accent colour, and a start page in the browser, all from `brand.json` ([ADR 0020](0020-brand-identity.md)).
- The bar at the bottom and the applications offered are declared (`tidepool.desktop.dash`: the browser first, then Files; `tidepool.desktop.apps`: Settings, the image, video and document viewers, the calculator). GNOME lists every desktop entry of the system, 35 of them here (disk and log tools, a manual, the Syncthing page...). A service hides, for this user only, every entry that is not offered, with an entry of the same name in its own folder. The admin and the system keep theirs; an application added later is hidden until it is named.
- Language: `tidepool.desktop.language` (`it_IT.UTF-8`, say) sets the language of the session's interface, GNOME and the browser, for this user only, the way Settings does it (the user's entry of AccountsService, which the login manager reads for the automatic login too). The machine's own language, and so its logs and messages, stays what `tidepool.locale.language` says (English by default: they are read and searched). On NixOS that alone is not enough: the login manager hands the language to the session, and `gnome-session` then loads the machine's environment, which sets `LANG` back to the machine's language; so the environment's last step puts it back for this user alone. The keyboard is the same kind of case: GNOME keeps its own list of input sources in the user's settings, written at the first login, so the declared layout (`tidepool.locale.keyboard`) is set in the locked settings too.
- Software: GNOME, Firefox. The terminal applications are left out of the session's menus.

## What it changes in [ADR 0005](0005-storage-layout-and-filesystem.md) and the [encryption runbook](../encryption-runbook.md)

Those pages said that a casual thief who switches the machine on gets nothing, because no local login exists. With the TPM unlocking the disks by itself, the machine now also boots into a logged-in session of the unprivileged user. Whoever is at the keyboard has a browser and can start a shell as that user. What stands between that and the data is: the services' files are owned by their users and not readable by others, the secrets are readable by root only, the databases and the other services listen on the machine or the VPN and ask for their own passwords, the user is in no group, and there is no `sudo`.

This is a convenience with a stated price, not a lock. A local user is more attack surface than none: a flaw in the kernel or in a setuid program could be a way up, and a service that listens on a Unix socket is protected only by that socket's file mode. The services' network ports are closed to that user by the rule above. I accept that, for a machine that is also a TV box, with the rights cut as far as they go. It is a switch: `tidepool.desktop.enable = false` returns to a console with no session.

## What it does not do

- It does not make the session a kiosk: a local user can start other programs (a shell too, from Firefox's file dialogs or its other features). The limit is what that user may do, not what it may start.
- Checks to repeat after a change, as that user: it cannot `sudo`; it cannot list or read the data of the services, the NAS share, the backups, the secrets or the signing keys (only the names of some folders are visible); it cannot connect to the databases; it cannot power off, restart or suspend from the menu (polkit's answers can be asked with `pkcheck`, never run); Syncthing's and Prometheus's interfaces are closed to it by the rule; the sound and the hardware video decode work in the browser. The lab has no screen, so the last one is only seen on real hardware.

## Found at the first reboots on real hardware

Three small things that the lab did not show, each seen in the journal of the first boots:

- An ordering cycle at every boot: `multi-user.target` waiting for `power-profile-default`, which waited for `power-profiles-daemon`, which starts after `multi-user.target`. The unit that sets the declared profile is now wanted by `graphical.target`, where the daemon itself is wanted. systemd had been dropping one job at each boot; the profile was applied anyway.
- The system reported "degraded" after every boot, because podman runs the container image's own health check once, a second after the start, before Jellyfin listens; that run is a transient unit that exits 1 and stays failed. The Jellyfin container now starts with `--no-healthcheck`, and the site stays watched by the HTTPS probe of the observability module (`/health`), which is the check that matters. The lab's gate had a known flake from the same cause: the first switch to the brand host failing with exit 4.
- The loader's random seed was readable by everybody (systemd's warning): the boot partition is mounted with `fmask=0077,dmask=0077`. Proved by a fresh install of the lab host and by the restore drill, which rebuilds the host from blank with these options.

## To decide after a few weeks of use

Keep it as it is, or move to a kiosk (one application, no desktop) if only a browser or a media client is ever used.
