# 0020. A shared brand: name, palette, logo

- **Status:** **accepted (2026-10-08)** and built: `nixos/modules/brand.nix`, `nixos/modules/sso.nix`, `nixos/brand/`. The owner's decisions are in the last section. The identity itself (the name's case, the six colours, the mark) is a **placeholder** until the owner replaces it.
- **Date:** 2026-10-07 (study), 2026-10-08 (decisions and build)
- **Phase:** after the first deployment is prepared; independent of it

## The question, and the answer

Can one **name, one palette and one logo** be set once, in one file, and show up on every service of the machine, public and private, without rewriting each program's design? And can another deployment of this code replace that file from its own private repository, leaving the code alone?

**Yes, with limits that depend on the program.** The brand goes where a program **has a setting for it** (Nextcloud's theming, Jellyfin's themes and branding, Immich's configuration, Prometheus' title); where it has none, nothing is done. No program is forked, patched or restyled from outside (that was tried and dropped: see "Update" below).  Everything below was run in the lab on the versions the flake pins: [`lab/brand-test.sh`](../../lab/brand-test.sh) (22 checks), [`lab/brand-check.sh`](../../lab/brand-check.sh) (a browser looks at the pages: 11 checks, and the single sign-on: 4), screenshots in [docs/evidence/brand-all.png](../evidence/brand-all.png). Its pure-Nix parts (the overrides, the contrast of the palette, the sign-on client's constraints, Jellyfin's theme) also run in the CI ([nixos/checks.nix](../../nixos/checks.nix)).

## How it is built

**The data is JSON** ([`nixos/brand/brand.json`](../../nixos/brand/brand.json), with `logo.svg`; the fields are explained in [its README](../../nixos/brand/README.md)): a name, a tagline, six colours with a role each, a square mark, and an optional outlined wordmark. JSON, so that tools that are not Nix can read the same file: the social-preview image is made from it by `nix build .#brand-preview` ([docs/brand/social-preview.png](../brand/social-preview.png)), and the README shows it.

**The brand is on by default**: a deployment that sets nothing shows this identity; `tidepool.brand.enable = false` turns it off.

**The module** turns the file into options (`tidepool.brand.name`, `.tagline`, `.colors.*`, `.logo`, `.wordmark`, and `.slug` for what must be a host name) and applies them. **A fork overrides it** from its private repository: `tidepool.brand.file = ./brand/brand.json;` (the fields it leaves out keep the defaults, `logo` is a file next to its JSON), or single options (`tidepool.brand.name = "Acme";`). Checked: a whole other file, a file with one field, one option, and the assets (the stylesheet, `favicon.ico`, the icons at 16, 32, 48, 180, 192 and 512 px) rebuilt from the other repository's logo. The icons are made at build time from the one SVG, cached by Nix, never committed.

**The palette** has six roles with their contrast checked (WCAG): white on `primary` 5.0, `text` on `sand` 12.3, `text` on `accent` 4.8, `sand` on `deep` 10.6, `primaryOnDark` on `deep` 5.7; **white on `accent` fails (2.9) and is not used**. Immich wants a twelve-step scale: it is made by mixing the one colour with white and black, in Nix.

| Service | What is applied, and how | Proven |
|---|---|---|
| **Nextcloud 33** | name, slogan, colours, background, logo, favicon: `nextcloud-brand.service` runs `occ theming:config` after the setup (**exception 5**); the database keeps it, so the backups do | the login page, in a browser |
| **Immich 3.2** | `theme.customCss` (palette scale, the logo by CSS), the login message, and the whole configuration **declared in the flake** (`tidepool.services.immich.settings`): Immich reads `IMMICH_CONFIG_FILE`, its admin page shows the settings read-only, and the file is rendered by sops-nix because the single sign-on's secret is in it | the config served, the page in a browser |
| **Single sign-on, Immich through Nextcloud** | `nixos/modules/sso.nix` (**exception 4**): the client is declared, registered after Nextcloud's setup (and again if its secret or addresses change), and Immich's OAuth section is written from the same declaration; the discovery document is answered at the address Immich asks (**its library does not follow a redirect**) | **end to end in a browser**: Immich's button, Nextcloud's login, back into Immich as a user created by the login |
| **Jellyfin 12.1** | **a theme of the brand**, the default one: Jellyfin Web has a theme system (`config.json` lists the themes, one is the default; each is a folder with a `theme.css` of variables). The module adds the brand's theme next to the six built-in ones and makes it the default, so every user who has not chosen a theme, and the login page, get it. It imports the dark theme and changes its variables, so it follows that theme's updates. Also `config/branding.xml` (login text, the logo by CSS) and the server name (the container's host name). A user who already chose a theme keeps it until they pick "Tidepool" in Settings > Display | the config and theme served, the page in a browser |
| **Prometheus** | the page title (`--web.page-title`, a flag) | the page, in a browser |
| **The machine** | the operating system's name (`os-release`, the boot menu's entries), the login message, the mail's sender name, Samba's server string and NetBIOS name | `os-release`; the rest are strings |
| **This repository** | the README's banner and GitHub's social preview, from the same JSON | the image; **the preview is uploaded by hand in the repository's settings** |
| **The phone and desktop apps** | **Nextcloud's apps follow the server**: it publishes the name, slogan, colour and logo in its capabilities (`/ocs/v2.php/cloud/capabilities`, checked in the lab), which is where its apps read them (not tried on a phone). **Jellyfin: the clients built on Jellyfin Web get the theme and the CSS**: the browser, the desktop player, the web-based TV apps, **and the official Android app, which is a WebView wrapper around Jellyfin Web** (its README says so); **the native ones do not** (Swiftfin on iOS, Android TV, Findroid). **Immich and Bitwarden's apps: no**: native, and the server has no theme for them | read in the capabilities; the Android wrapper from the project's README |
| **Looked at, not done** | Syncthing's own dark theme as the default (`gui.theme`); Nextcloud's light/dark choice stays the user's. | |
| **Not done: no setting for it** | ntfy (the documentation has none), Incus UI (nothing found), Vaultwarden, Syncthing, Alertmanager (no theme setting), the native phone apps | |

## The check at every update

A program can rename a variable, a class or a setting. The failure is cosmetic, never a broken service, and it is caught by **`lab/gate.sh`** (its `brand` step, [lab/README.md](../../lab/README.md)): run it in the lab **at every update of Jellyfin, Immich, Nextcloud and Prometheus** (a FAIL names the page and what is missing; the screenshots are the human look). For Jellyfin there is one more comparison: the module serves **the image's own `config.json`** (copied in `nixos/brand/jellyfin-web-config.json`) with the theme added, and `lab/brand-test.sh` fails if it differs from the pinned image's by anything but the themes, which is what a new Jellyfin version that adds a plugin to its list would do. It is the "test run at every upgrade" of exceptions 4 and 5 ([the register](../exceptions.md)).

## What it costs, and what it risks

- **Three exceptions to P1** in the register (the sign-on units, Nextcloud's theming commands, Jellyfin's served config); each has its test.
- **Immich and its settings file** (measured on v3.2.4): a key it does not know is **ignored with a warning** (the setting is lost silently: a renamed key shows up as a missing setting); a value of the wrong type, or a broken file, makes it **refuse to start** (`Invalid system config`), which is a failed unit and an alert. The step `brand` of the gate checks that it starts on the declared file and serves it; run it at every Immich update.
- **Immich's settings are now code.** Changing one means editing `tidepool.services.immich.settings` (or a private repository's addition to it), not the admin page. What is not named keeps Immich's default.
- **The secret of the sign-on client** is in `secrets.yaml`, rendered into Immich's file by sops-nix at activation; nothing is in the Nix store (checked). Nextcloud's `occ` receives it as an argument for a moment, on a machine with one administrator.
- **Users:** Immich creates a user at the first login through Nextcloud (the account needs an email address). What happens to users that already exist in Immich (v0's) with the same email is **not tried**: it is a check for the day ([pending](../pending.md)).
- **Names.** Changing a displayed name is fine for one's own use; a rebranded **redistribution** of Bitwarden's web client would need a look at its trademark and licence terms. The module does not rename Nextcloud, Jellyfin or Immich in their code, only the instance's displayed name and look.
- **A wordmark** (the logo with the name in letters) must be **outlined** by whoever designs it: rendering text to images in the build would need a font. It is optional; the mark is used where there is none.
- **The lab does not verify the single sign-on's certificates** (its CA changes at every start); on the real machine the certificates are Let's Encrypt's.

## The owner's decisions (2026-10-08)

1. The data file is **JSON**, with Nix reading it.
2. Immich: **all its settings are declared in the flake**, and **the link with Nextcloud (the single sign-on) too**.
3. The identity: **the placeholder stays** (the name `Tidepool`, the deep teal and sea green, the coral, the sand, the wave mark) until the owner chooses.
4. The programs' own logos are replaced where a program lets it be done, **with the check at every update** above.
5. **No home page** at the domain's apex: it stays empty.

## Update (2026-10-08, later): reduced to what the programs support

The owner asked to keep **only the parts a program supports** and to drop the tricks. Removed: the **patched Vaultwarden web vault** (a copy of the package with replaced images and a stylesheet), and the **stylesheet that nginx added** to Prometheus', Alertmanager's and Syncthing's pages, with the icons and the stylesheet built for them. Why: each depended on a program's internals (a class name, a variable, the layout of `index.html`); one of them (Vaultwarden's colour variables) had already been renamed once in 2026; the patch could fail the whole build on an update (`substituteInPlace` on a file that changed), blocking every deploy until it was mended; and seven programs restyled from outside is a maintenance burden for a cosmetic gain. What remains is what a program lets be set. The module went from 145 to 96 lines and the register lost its fragile entry.

