#!/usr/bin/env bash
# =============================================================================
# lab/brand-test.sh — the brand module (nixos/modules/brand.nix, ADR 0020) and the single sign-on (nixos/modules/sso.nix): what they change on a running lab host, and that another repository
# can override the brand. The pages themselves are looked at by lab/brand-check.sh.
#
# Usage: lab/brand-test.sh <vm-name>      (a NixOS lab VM with the services; it is switched to the host lab-brand)
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="${1:?usage: brand-test.sh <vm-name>}"
tar -C "$HERE/.." -c nixos | "$HERE/vm.sh" ssh "$NAME" 'rm -rf ~/nn && mkdir ~/nn && tar x -C ~/nn'
"$HERE/vm.sh" ssh "$NAME" 'bash -s' <<'REMOTE_EOF'
r() { local desc="$1" want="$2"; shift 2; local got; got=$("$@" 2>/dev/null); if [ "$got" = "$want" ]; then echo "PASS $desc"; else echo "FAIL $desc (wanted '$want', got '$got')"; fi; }
has() { local desc="$1" re="$2"; shift 2; if "$@" 2>/dev/null | grep -q -E -e "$re"; then echo "PASS $desc"; else echo "FAIL $desc (no match for $re)"; fi; }
cd ~/nn/nixos
sudo rm -rf /var/lib/acme/.lego/accounts; sudo systemctl reset-failed
sudo nixos-rebuild test --flake path:$PWD#lab-brand 2>&1 | tail -1
sudo systemctl restart "acme-order-renew-*.service" nginx; sleep 15
V=10.100.0.1
r "the operating system carries the name"                      "NAME=Tidepool" grep -E "^NAME=" /etc/os-release
r "the unit that applies the brand to Nextcloud ran"           "active" systemctl is-active nextcloud-brand
r "Nextcloud's theming has the name"                           "Tidepool" sudo nextcloud-occ config:app:get theming name
r "Nextcloud's theming has the primary colour"                 "#0f7a8c" sudo nextcloud-occ config:app:get theming primary_color
has "Nextcloud's login page says the name"                     "Tidepool" curl -sk --resolve cloud.lab.test:443:127.0.0.1 https://cloud.lab.test/login
r "Prometheus has the name in its title"                       "<title>Tidepool metrics" bash -c "curl -sk --resolve metrics.lab.test:443:$V https://metrics.lab.test/query | grep -o '<title>[^<]*'"
# another repository overrides it: one field at a time, or the whole file, with its own logo
cat > ~/nn/other-logo.svg <<S
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><circle cx="32" cy="32" r="28" fill="#aa3355"/></svg>
S
cat > ~/nn/other-brand.json <<N
{ "name": "Acme Home", "tagline": "ours", "colors": { "deep": "#220011", "primary": "#aa3355", "primaryOnDark": "#ff8fa8", "accent": "#33aa77", "sand": "#fff5f7", "text": "#220011" }, "logo": "other-logo.svg" }
N
cat > ~/nn/partial-brand.json <<N
{ "name": "Partial Co" }
N
ev() { nix eval --impure --raw --expr "let f = builtins.getFlake \"path:$HOME/nn/nixos\"; mk = mods: (f.nixosConfigurations.lab-brand.extendModules { modules = mods; }).config; $1" 2>/dev/null; }
r "a brand file with one field keeps the other defaults"       "Partial Co|#0b3c49|your own cloud" ev 'a = mk [ { tidepool.brand.file = /home/lab/nn/partial-brand.json; } ]; in "${a.tidepool.brand.name}|${a.tidepool.brand.colors.deep}|${a.tidepool.brand.tagline}"'
r "one option overridden, the others stay"                      "Acme|#0b3c49|your own cloud" ev 'a = mk [ { tidepool.brand.name = "Acme"; } ]; in "${a.tidepool.brand.name}|${a.tidepool.brand.colors.deep}|${a.tidepool.brand.tagline}"'
r "a brand file of another repository replaces the brand"      "Acme Home|#aa3355|acme-home|Acme Home" ev 'a = mk [ { tidepool.brand.file = /home/lab/nn/other-brand.json; } ]; in "${a.tidepool.brand.name}|${a.tidepool.brand.colors.primary}|${a.tidepool.brand.slug}|${a.system.nixos.distroName}"'
r "the other repository's logo is the one used"              "other-logo.svg" ev 'a = mk [ { tidepool.brand.file = /home/lab/nn/other-brand.json; } ]; in baseNameOf (toString a.tidepool.brand.logo)'
# the single sign-on and Immich's declared settings
r "the unit that registers the single sign-on clients ran"     "active" systemctl is-active nextcloud-oidc-clients
r "Nextcloud knows the Immich client"                          "Immich" bash -c "sudo nextcloud-occ oidc:list | jq -r '.[0].name'"
r "the discovery document is answered at the address Immich asks" "200" curl -sk -o /dev/null -w '%{http_code}' --resolve cloud.lab.test:443:127.0.0.1 https://cloud.lab.test/.well-known/openid-configuration
r "Immich reads its settings from the declared file"           "Login with Tidepool" bash -c "curl -s localhost:2283/api/server/config | jq -r .oauthButtonText"
r "Immich's external domain is the declared one"               "https://photos.lab.test" bash -c "curl -s localhost:2283/api/server/config | jq -r .externalDomain"
has "Immich serves the brand's stylesheet"                     "immich-primary: 15 122 140" curl -s localhost:2283/custom.css
r "the client secret is not in the Nix store"                  "0" bash -c "grep -rl \$(sudo cat /run/secrets/immich-oauth-secret) /nix/store --include=*.json 2>/dev/null | wc -l"
r "Jellyfin's branding file is written"                        "Tidepool - your own cloud" bash -c "curl -s localhost:8096/Branding/Configuration | jq -r .LoginDisclaimer"
# Jellyfin's web themes: the brand's theme is the default and the rest of the config is the image's own
img=$(sudo podman inspect jellyfin --format '{{.ImageName}}')
orig=$(sudo podman run --rm --entrypoint cat "$img" /jellyfin/jellyfin-web/config.json | jq -S 'del(.themes)')
served=$(curl -s localhost:8096/web/config.json | jq -S 'del(.themes)')
r "Jellyfin's web config is the image's, but for the themes"   "same" bash -c "[ \"\$1\" = \"\$2\" ] && echo same || echo different" _ "$orig" "$served"
r "the brand's theme is Jellyfin's default theme"              "tidepool" bash -c "curl -s localhost:8096/web/config.json | jq -r '.themes[] | select(.default == true) | .id'"
r "the built-in themes are still offered"                      "6" bash -c "curl -s localhost:8096/web/config.json | jq '[.themes[] | select(.id != \"tidepool\")] | length'"
r "the theme file is served"                                   "200" curl -s -o /dev/null -w '%{http_code}' localhost:8096/web/themes/tidepool/theme.css
# the lab's test CA can refuse an order that comes in the same second as its start: an ACME order that failed is tried once more, any other unit is reported as it is
for u in $(systemctl --failed --no-legend | sed 's/^[^a-zA-Z]*//' | cut -d' ' -f1 | grep '^acme-order-renew-'); do sudo systemctl reset-failed "$u"; sudo systemctl restart "$u"; done; sleep 5
systemctl --failed --no-legend | sed 's/^[^a-zA-Z]*//' | cut -d" " -f1 | sed 's/^/failed unit: /'
echo "failed units: $(systemctl --failed --no-legend | wc -l)"
REMOTE_EOF
