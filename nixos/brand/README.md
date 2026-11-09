# The brand

`brand.json` and `logo.svg` are the default brand of tidepool: a name, a tagline, the label of each service, the text of the sign-in button, six colours and a square mark. `modules/brand.nix` applies them where a program has a setting for it ([ADR 0020](../../docs/decisions/0020-brand-identity.md)). The values here are placeholders for a real identity.

| Field | Default | Meaning |
|---|---|---|
| `name` | `Tidepool` | the brand's name: in a footer, a banner or a tagline, on its own ("Tidepool, your own cloud"); in the system's name, Samba, the mail's sender and the recap's greeting |
| `tagline` | `your own cloud` | a few words after the name |
| `labels.cloud`, `labels.photos`, `labels.media`, `labels.track`, `labels.admin`, `labels.metrics` | `Cloud`, `Photos`, `Media`, `Track`, `Admin`, `Metrics` | the word after the name in the **name of a service**, `<name> <label>` ("Tidepool Cloud"): what a page calls itself in its title and its browser tab, what an app shows as the server's name. A name of "Pippo" gives "Pippo Cloud", "Pippo Photos", "Pippo Media"; an empty label leaves the name alone |
| `signInLabel` | `Sign in with SSO` | the text of the single sign-on button in Immich, Floppy and Jellyfin: generic, so that a page that already carries the brand does not say its name twice |
| `colors.deep` | `#0b3c49` | headers and dark backgrounds |
| `colors.primary` | `#0f7a8c` | buttons and links on light backgrounds (white text on it: contrast 5.0) |
| `colors.primaryOnDark` | `#4fc3d4` | the same role on `deep` and in dark themes (contrast 5.7) |
| `colors.accent` | `#e8765a` | the one warm note; **dark text on it, never white** (white on it: 2.9) |
| `colors.sand`, `colors.text` | `#f4f1ea`, `#12303a` | light backgrounds and the text on them (12.3) |
| `logo` | `logo.svg` | a square SVG, relative to this file; the favicons and app icons of Immich, Jellyfin and Floppy are made from it at build time and served by the edge (Nextcloud's theming takes the SVG itself) |
| `wordmark` | `null` | optional: an SVG of the mark with the name in letters, **outlined** (no live text), for the wide places (Jellyfin's login logo, Floppy's logo); `null` uses the mark |

The brand is **on by default**: a deployment that sets nothing shows this identity on every service that can take it; `tidepool.brand.enable = false;` turns it off.

**Another deployment** copies this directory (or `private-repo-template/brand/`) into its private repository, edits it, and says `tidepool.brand.file = ./brand/brand.json;` in `host.nix` (fields it leaves out keep these defaults); or sets single fields (`tidepool.brand.name = "Acme";`, `tidepool.brand.labels.cloud = "Home";`, `tidepool.brand.signInLabel = "…";`). One change reaches every program in the table below. The name of each service is also available to other modules as `config.tidepool.brand.product.<service>`; a name or a label may not contain a quote, a dollar sign, a semicolon or a backslash (it is written into a web server's configuration; the build refuses it).

## What follows the brand

| Program | Name of the page, the tab and the app | Footer, banner | Sign-in text | Logo | Palette |
|---|---|---|---|---|---|
| Nextcloud (and its apps) | `<name> <cloud>`: the tab, the login heading, the mobile app's server name | `<name>` and the tagline (the edge corrects the one footer field, below) | n/a | yes, and the favicon | yes |
| Immich | `<name> <photos>` in the tab: the edge rewrites the one place where its web client writes the title (exception 11); its login page names the brand | `<name>, <tagline>` on the login page | the button's text | yes (login and the interface), its favicon and app icons by the edge | its primary scale; its backgrounds are Immich's |
| Jellyfin (and the clients built on its web) | `<name> <media>`: the server's name, which is the tab and the apps' name | `<name> - <tagline>` | the button's text | yes (the wordmark if there is one), its favicon and app icons by the edge | a whole theme, the default |
| Floppy | `<name> <track>`: the title and the installed app's name, rewritten by the edge | n/a | the button's text | yes (replaced by the edge's stylesheet), its favicon and app icons by the edge | yes, forced by the same stylesheet |
| The admin page | `<name> <admin>` | n/a | n/a | no | the background; its text colour is one of Homepage's fixed names |
| Prometheus | `<name> <metrics>` | n/a | n/a | no | no |
| The system, Samba, the mail's sender | `<name>` | n/a | n/a | n/a | n/a |
| The TV session | the tiles and bookmarks of the start page use the names of the services | n/a | n/a | the wallpaper and the start page | yes (GNOME's nearest accent, the start page) |
| Alertmanager, ntfy, Syncthing, Vaultwarden's web vault, Incus's UI | no setting | | | no | no |

A page that a private repository adds is its own to style; it does not read the brand unless it is written to.

**What a program does not let be set**, said plainly: Immich writes its own tab title ("… - Immich") in the browser, with no setting, so the edge rewrites that one place of its web client (exception 11; a browser that cached the old file shows the old title until a hard reload); Nextcloud's theming has **one** field for the name of the page, the tab and the footer, so the footer's repeat of the service's name ("Tidepool Cloud – your own cloud") is corrected by the edge (`docs/exceptions.md`, entry 10); Jellyfin's server name is a setting of the program, written in its settings file before each start (that one element, in place), so a name typed into its dashboard is replaced at the next start.

## The TV session

When the TV session is on ([ADR 0022](../../docs/decisions/0022-the-tv-session.md)), the same brand sets its wallpaper, GNOME's dark style and nearest accent colour, and the start page and bookmarks of its browser (`modules/desktop-brand.nix`, [ADR 0020](../../docs/decisions/0020-brand-identity.md)). Nothing to add: a private repository that changes `brand.json` changes it too; `tidepool.desktop.startPage.links` adds its own tiles.

## Jellyfin's theme

`jellyfin-web-config.json` is **the pinned Jellyfin image's own `config.json`** (the list of web themes and plugins), which the module serves instead of the image's, with the brand's theme added and made the default. When the image's digest changes, refresh it (`podman run --rm --entrypoint cat <image> /jellyfin/jellyfin-web/config.json > nixos/brand/jellyfin-web-config.json`); `lab/brand-test.sh` compares the two and fails if they differ by anything but the theme.
