# 0021. One admin page for the private tools

- **Status:** accepted as a trial (2026-10-08): built and proven in the lab (`nixos/modules/admin.nix`, off by default); the owner decides after using it on the real machine
- **Date:** 2026-10-08
- **Phase:** after the first deployment is prepared

## The question

The machine's private tools are reachable only through the VPN and each has its own name (`metrics.`, `alerts.`, `sync.`, `compute.`:8443): Prometheus, Alertmanager, Syncthing, Incus. Can they, and the services, be one click from each other, in one place, with a sign of whether each answers? The owner asked about a plugin of Nextcloud, Grafana, or something like Backstage.

## What was considered

[ADR 0012](0012-observability.md) had looked at the neighbouring question (a dashboard to *find problems*) and decided against it: alerts find problems; Grafana was tried (it starts with Prometheus provisioned, 217 MiB) and left as an `enable` away. A *launcher* of the private tools had not been considered.

| Option | Verdict |
|---|---|
| **Homepage** (gethomepage.dev; `services.homepage-dashboard` in nixpkgs, 1.12.3) | **chosen for the trial**: a page of links with a status dot per service (an HTTP check from the machine itself) and widgets (Prometheus' targets, the machine's CPU, memory and disks). Declared in Nix, no script. |
| Glance, Homer, Dashy | the same idea, with fewer widgets or a heavier page; NixOS modules exist. Not tried. |
| Grafana | for trends over time, not for a launcher; stays optional. |
| Cockpit | a web console of the machine (units, logs, containers): another way into the host with the system login, so a security decision of its own. Not now. |
| Uptime Kuma, Netdata | status pages and live metrics; not tried. |
| Backstage | a developer portal (a catalogue and templates for teams): a Node application with a database and a build, no NixOS module. The wrong tool. |
| A plugin of Nextcloud | its Dashboard and "External sites" cannot frame the private pages (nginx sends `X-Frame-Options: SAMEORIGIN` and the origins differ), and the admin page would be down whenever Nextcloud is. No. |

## What was built, and proved

`tidepool.admin.enable` (off by default: it needs the name `admin.<domain>` in the DNS, an A record to 10.100.0.1, [names](../names.md)). Homepage listens on **the loopback only** (`HOSTNAME=127.0.0.1`: the Next.js server otherwise listens everywhere) and nginx serves it on the **VPN address only**. The groups: Monitoring (Prometheus with its widget, Alertmanager), Machine (Syncthing, Incus, ntfy), Services (Nextcloud, Immich, Jellyfin, Vaultwarden). The status of each is asked of the machine itself, by a loopback address where the program has one (the public names would need the router to loop back); the brand gives the title and the colours ([ADR 0020](0020-brand-identity.md)).

In the lab ([docs/evidence/admin-page.png](../evidence/admin-page.png)): the page answers on the VPN address; every service shows a green status; Prometheus' widget reads 9 targets up, 0 down, 29 in total; the page lists the tools and links to their own addresses (`lab/brand-check.sh`, in the gate's `brand` step). **It uses about 250 MB of memory** (measured on the lab host, with the Next.js server resident), which is more than all the other observability pieces together (about 107 MiB without Grafana).

## What it does not do

- No login of its own: the VPN is the boundary, as for the tools it lists. A link to a tool still asks for that tool's own login.
- Nextcloud's status uses its public name (`/status.php`), which on the real machine goes out and back through the router unless the router loops back or the names are given a local answer; if that dot is red while Nextcloud works, that is why.
- Incus has no status dot (it answers only with a client certificate).
- It does not replace the alerts: a failed unit still arrives as mail and push; the page is for looking.

## To decide after a few weeks of use
Keep it, replace it by one of the other launchers, or drop it (`tidepool.admin.enable = false`); and whether Grafana is then wanted next to it for the trends.
