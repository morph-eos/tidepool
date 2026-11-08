# Jellyfin's sign-in through Nextcloud

Jellyfin has no single sign-on of its own: a plugin, **SSO Authentication** (from Jellyfin's plugin catalog), adds a button to its login page that sends the user to an OpenID Connect provider, here Nextcloud's `oidc` app ([ADR 0011](../../../docs/decisions/0011-services.md)). Everything the plugin needs is declared, so nothing is typed into Jellyfin's settings:

```nix
tidepool.sso.enable = true;
tidepool.sso.jellyfin.enable = true;   # the client, the plugin and its settings, the button
```

and the secret `jellyfin-oauth-secret` (32 to 64 printable characters, no colon; `private-repo-template/tools/secrets-init.sh` makes one).

## What `tidepool.sso.jellyfin.enable` does

| Piece | Where | What |
|---|---|---|
| The client | `modules/sso.nix` | Nextcloud's `oidc` app gets a client named Jellyfin, with the secret from sops and the redirect address `https://media.<domain>/sso/OID/redirect/<provider>` (the same unit that registers Immich's and Floppy's). |
| The plugin | `modules/sso.nix` | Before Jellyfin starts, the plugin (a pinned release, from its zip) is put in Jellyfin's plugin directory **when there is none there**. One that is installed already, in any version, is left as it is (`tidepool.sso.jellyfin.installPlugin = false` never installs). |
| The plugin's settings | `sso-config.sh` | Before Jellyfin starts, the provider's endpoint, client id, secret and enabled flag are written in the plugin's own file (`SSO-Auth.xml`), from the same declaration. |
| The button | `modules/brand.nix` | A form under the brand's line in Jellyfin's login message, going to `/sso/OID/start/<provider>`, with the text of the brand's `signInLabel` (generic: "Sign in with SSO"). `tidepool.brand.jellyfinLoginHtml` replaces it with other HTML. |

`<provider>` is `nextcloud` unless `tidepool.sso.jellyfin.provider` says another name. A client that exists in Nextcloud under another id (made by hand) is adopted with `tidepool.sso.clients.jellyfin.clientId = "<its id>";` and its secret in `jellyfin-oauth-secret`: the same id and secret mean the login that works keeps working; the unit replaces the client only when its secret or its addresses differ from the declaration.

## `sso-config.sh`

The script that writes the settings can be run by hand, to see what it would do:

```sh
sso-config.sh --config-dir /srv/data/jellyfin/config/plugins/configurations \
  --provider nextcloud --endpoint https://cloud.example.org --client-id <id> --secret-file /run/secrets/jellyfin-oauth-secret --check
```

- A file that is not there is written (mode 600), with the settings the lab proved: authorization off, every folder, the scopes `openid profile email groups`, https.
- A provider that is there and already as declared: nothing to do.
- A provider that is there with other values: **left alone**, and the differing fields are named (never the id's or the secret's value); `--adopt` updates the four fields it owns (endpoint, client id, secret, enabled) in place. What else is in the file, the links between Nextcloud's users and Jellyfin's among it, stays. The module runs it with `--adopt`: the declaration is the authority.
- The secret is read from a file, and only compared and written inside the process: it is on no command line and in no output.
- Exit codes: 0 done or nothing to do, 10 `--check` found something it would change, 3 a difference that was not adopted, 4 a settings file that is not valid XML (nothing is changed), 2 a wrong call.

A failure of the script is told in the journal and does not stop Jellyfin.

## What is proven

The CI's `brand` check runs the script on a temporary directory (a missing file is written valid and private, a differing provider is not touched, `--adopt` updates the four fields and keeps the links, a second provider is added) and evaluates the module (the client, the button, the adopted id). Jellyfin 12 loads the plugin and the file the script writes (the plugin is listed as active). The lab (`lab/brand-test.sh`) switches a VM to a host with all of it on and looks at what is installed, written and served.

## What is not proven

- **A whole login in a browser**, from Jellyfin's page through Nextcloud and back into a Jellyfin session, is not part of the lab: Jellyfin's container does not trust the lab's test certificates, so it cannot fetch Nextcloud's discovery document there. On a real machine the certificates are public ones.
- A plugin **update** (the catalog's auto-update) is not tried.
