# The brand

`brand.json` and `logo.svg` are the default brand of tidepool: a name, a tagline, six colours and a square mark. `modules/brand.nix` applies them where a program has a setting for it ([ADR 0020](../../docs/decisions/0020-brand-identity.md)). The values here are placeholders for a real identity.

| Field | Meaning |
|---|---|
| `name`, `tagline` | shown where a program lets a name be set (Nextcloud, Immich's login page, the operating system, Prometheus' title, Jellyfin's login text) |
| `colors.deep` | headers and dark backgrounds |
| `colors.primary` | buttons and links on light backgrounds (white text on it: contrast 5.0) |
| `colors.primaryOnDark` | the same role on `deep` and in dark themes (contrast 5.7) |
| `colors.accent` | the one warm note; **dark text on it, never white** (white on it: 2.9) |
| `colors.sand`, `colors.text` | light backgrounds and the text on them (12.3) |
| `logo` | a square SVG, relative to this file; the favicons and app icons are made from it at build time |
| `wordmark` | optional: an SVG of the mark with the name in letters, **outlined** (no live text), for the wide places (Jellyfin's login logo); `null` uses the mark |

The brand is **on by default**: a deployment that sets nothing shows this identity on every service that can take it; `tidepool.brand.enable = false;` turns it off.

**Another deployment** copies this directory into its private repository, edits it, and says `tidepool.brand.file = ./brand/brand.json;` in `host.nix` (fields it leaves out keep these defaults); or sets single fields (`tidepool.brand.name = "Acme";`).

## Jellyfin's theme

`jellyfin-web-config.json` is **the pinned Jellyfin image's own `config.json`** (the list of web themes and plugins), which the module serves instead of the image's, with the brand's theme added and made the default. When the image's digest changes, refresh it (`podman run --rm --entrypoint cat <image> /jellyfin/jellyfin-web/config.json > nixos/brand/jellyfin-web-config.json`); `lab/brand-test.sh` compares the two and fails if they differ by anything but the theme.
