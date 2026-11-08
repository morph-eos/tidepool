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
out=$(mktemp)
"$HERE/vm.sh" ssh "$NAME" 'bash -s' <<'REMOTE_EOF' | tee "$out"
r() { local desc="$1" want="$2"; shift 2; local got; got=$("$@" 2>/dev/null); if [ "$got" = "$want" ]; then echo "PASS $desc"; else echo "FAIL $desc (wanted '$want', got '$got')"; fi; }
has() { local desc="$1" re="$2"; shift 2; if "$@" 2>/dev/null | grep -q -E -e "$re"; then echo "PASS $desc"; else echo "FAIL $desc (no match for $re)"; fi; }
cd ~/nn/nixos
sudo rm -rf /var/lib/acme/.lego/accounts; sudo systemctl reset-failed
sudo nixos-rebuild test --flake path:$PWD#lab-brand > /tmp/switch.log 2>&1; rc=$?; tail -n 1 /tmp/switch.log; [ $rc -eq 0 ] || { echo "FAIL the switch to the host lab-brand failed (exit $rc): $(grep -m1 -i 'error' /tmp/switch.log | cut -c1-160)"; }
sudo systemctl restart "acme-order-renew-*.service" nginx; sleep 15
V=10.100.0.1
r "the operating system carries the name"                      "NAME=Tidepool" grep -E "^NAME=" /etc/os-release
r "the unit that applies the brand to Nextcloud ran"           "active" systemctl is-active nextcloud-brand
r "Nextcloud's theming has the name of the service"           "Tidepool Cloud" sudo nextcloud-occ config:app:get theming name
r "Nextcloud's theming has the primary colour"                 "#0f7a8c" sudo nextcloud-occ config:app:get theming primary_color
has "Nextcloud's login page says the name of the service"      "<title>[^<]*Tidepool Cloud" bash -c "curl -sk --resolve cloud.lab.test:443:127.0.0.1 https://cloud.lab.test/login | tr -d '\n'"
has "the footer is right for a browser too (a client that takes compression)" "entity-name\">Tidepool</a> – your own cloud" bash -c "curl -sk -H 'Accept-Encoding: gzip, deflate, br' --resolve cloud.lab.test:443:127.0.0.1 https://cloud.lab.test/login | gunzip -c"
has "Nextcloud's footer says the brand's name and the tagline" "entity-name\">Tidepool</a> – your own cloud" curl -sk --resolve cloud.lab.test:443:127.0.0.1 https://cloud.lab.test/login
r "Prometheus has the name in its title"                       "<title>Tidepool Metrics" bash -c "curl -sk --resolve metrics.lab.test:443:$V https://metrics.lab.test/query | grep -o '<title>[^<]*'"
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
r "an extra login HTML is added to Jellyfin's login message"    "yes" ev 'a = mk [ { tidepool.brand.jellyfinLoginHtml = "<a href=\"/sso\">Sign in</a>"; } ]; in if builtins.any (x: builtins.match ".*branding[.]xml.*your own cloud&lt;br&gt;&lt;a href=&quot;/sso&quot;&gt;Sign in&lt;/a&gt;.*" x != null) a.systemd.tmpfiles.rules then "yes" else "no"'
r "a brand file of another repository replaces the brand"      "Acme Home|#aa3355|acme-home|Acme Home" ev 'a = mk [ { tidepool.brand.file = /home/lab/nn/other-brand.json; } ]; in "${a.tidepool.brand.name}|${a.tidepool.brand.colors.primary}|${a.tidepool.brand.slug}|${a.system.nixos.distroName}"'
r "the other repository's logo is the one used"              "other-logo.svg" ev 'a = mk [ { tidepool.brand.file = /home/lab/nn/other-brand.json; } ]; in baseNameOf (toString a.tidepool.brand.logo)'
r "a brand that names everything: every title and label is its own" "Pippo Nuvola|Pippo Foto|Pippo Film|Pippo Diario|Pippo Regia|Pippo Numeri|Entra con Pippo" ev 'a = mk [ { tidepool.brand.file = /home/lab/nn/nixos/brand/test/pippo-brand.json; } ]; p = a.tidepool.brand.product; in "${p.cloud}|${p.photos}|${p.media}|${p.track}|${p.admin}|${p.metrics}|${a.tidepool.brand.signInLabel}"'
r "only the name changed: every service is <name> and its default label" "Pippo Cloud|Pippo Photos|Pippo Media|Pippo Track" ev 'a = mk [ { tidepool.brand.name = "Pippo"; } ]; p = a.tidepool.brand.product; in "${p.cloud}|${p.photos}|${p.media}|${p.track}"'
# the single sign-on and Immich's declared settings
r "the unit that registers the single sign-on clients ran"     "active" systemctl is-active nextcloud-oidc-clients
r "Nextcloud knows the Immich client"                          "Immich" bash -c "sudo nextcloud-occ oidc:list | jq -r '.[0].name'"
r "the discovery document is answered at the address Immich asks" "200" curl -sk -o /dev/null -w '%{http_code}' --resolve cloud.lab.test:443:127.0.0.1 https://cloud.lab.test/.well-known/openid-configuration
r "Immich reads its settings from the declared file"           "Sign in with SSO" bash -c "curl -s localhost:2283/api/server/config | jq -r .oauthButtonText"
r "Immich's external domain is the declared one"               "https://photos.lab.test" bash -c "curl -s localhost:2283/api/server/config | jq -r .externalDomain"
has "Immich serves the brand's stylesheet"                     "immich-primary: 15 122 140" curl -s localhost:2283/custom.css
r "Nextcloud knows the Floppy client"                          "Floppy" bash -c "sudo nextcloud-occ oidc:list | jq -r '.[] | select(.name == \"Floppy\") | .name'"
has "Floppy's tab says the name of the service, not its own"  "Tidepool Track" bash -c "curl -sk --resolve track.lab.test:443:127.0.0.1 https://track.lab.test/accounts/login/ | tr -d '\n' | grep -o '<title>[^<]*</title>' | tr -s ' '"
r "Floppy's sign-up form is not served (the sign-on is the way in)" "404" curl -sk -o /dev/null -w '%{http_code}' --resolve track.lab.test:443:127.0.0.1 https://track.lab.test/accounts/signup/
r "Floppy's pages link the brand's stylesheet, and it is served" "1 1" bash -c "a=\$(curl -sk --resolve track.lab.test:443:127.0.0.1 https://track.lab.test/accounts/login/ | grep -c '/_brand/theme.css'); b=\$(curl -sk --resolve track.lab.test:443:127.0.0.1 https://track.lab.test/_brand/theme.css | grep -c -- '--color-accent: #4fc3d4 !important'); echo \$a \$b"
# the accounts follow Nextcloud's list of people: two users without an address (the case that could clash), none has signed in to Floppy
for u in acctest1 acctest2; do sudo nextcloud-occ user:delete $u >/dev/null 2>&1; sudo env OC_PASS=Acc-test-pass-12345 nextcloud-occ user:add --password-from-env $u >/dev/null 2>&1; done
r "floppy-accounts runs and ends well"                          "0" bash -c "sudo systemctl start floppy-accounts.service >/dev/null 2>&1; echo \$?"
r "Floppy has an account and a sign-on link for each user"      "2 2" bash -c "a=\$(sudo psql -h /run/postgresql -U floppy -d floppy -tAc \"select count(*) from users_user where username in ('acctest1','acctest2')\"); b=\$(sudo psql -h /run/postgresql -U floppy -d floppy -tAc \"select count(*) from socialaccount_socialaccount where provider = 'sso' and uid in ('acctest1','acctest2')\"); echo \$a \$b"
r "a second run makes nothing new"                              "made 0, linked 0" bash -c "sudo systemctl start floppy-accounts.service >/dev/null 2>&1; sudo journalctl -u floppy-accounts.service -n 5 --no-pager | grep -o 'made 0, linked 0' | tail -1"
for u in acctest1 acctest2; do sudo nextcloud-occ user:delete $u >/dev/null 2>&1; done
r "Floppy's client secret is not in the Nix store"             "0" bash -c "grep -rl \$(sudo cat /run/secrets/floppy-oauth-secret) /nix/store 2>/dev/null | wc -l"
r "the client secret is not in the Nix store"                  "0" bash -c "grep -rl \$(sudo cat /run/secrets/immich-oauth-secret) /nix/store --include=*.json 2>/dev/null | wc -l"
r "Jellyfin's server name is the name of the service (it is the tab and the apps' name)" "Tidepool Media" bash -c "sudo systemctl restart podman-jellyfin.service; for i in \$(seq 1 40); do n=\$(curl -s localhost:8096/System/Info/Public | jq -r .ServerName 2>/dev/null); [ -n \"\$n\" ] && [ \"\$n\" != null ] && break; sleep 3; done; echo \$n"
has "Jellyfin's branding file is written, the brand's line first" "^Tidepool - your own cloud<br>" bash -c "curl -s localhost:8096/Branding/Configuration | jq -r .LoginDisclaimer"
# Jellyfin's sign-in through Nextcloud (nixos/jellyfin/sso/): the client, the plugin, its settings, the button
f=/srv/data/jellyfin/config/plugins/configurations/SSO-Auth.xml
r "Nextcloud knows the Jellyfin client"                        "Jellyfin" bash -c "sudo nextcloud-occ oidc:list | jq -r '.[] | select(.name == \"Jellyfin\") | .name'"
r "the Jellyfin client's address is the plugin's redirect"     "https://media.lab.test/sso/OID/redirect/nextcloud" bash -c "sudo nextcloud-occ oidc:list | jq -r '.[] | select(.name == \"Jellyfin\") | .redirect_uris[0]'"
r "the plugin is in Jellyfin's plugin directory"               "yes" bash -c "sudo ls /srv/data/jellyfin/config/plugins | grep -q '^SSO Authentication_' && echo yes"
r "its settings file is private"                               "600" sudo stat -c %a $f
r "its settings name the provider and the address"             "2" bash -c "sudo grep -c -e '<string>nextcloud</string>' -e '<OidEndpoint>https://cloud.lab.test</OidEndpoint>' $f"
r "the secret in the settings is the declared one (compared, not shown)" "yes" bash -c "[ \"\$(sudo grep -o '<OidSecret>[^<]*' $f | cut -c12-)\" = \"\$(sudo cat /run/secrets/jellyfin-oauth-secret)\" ] && echo yes"
r "Jellyfin loaded the plugin"                                  "yes" bash -c "sudo podman logs jellyfin 2>&1 | grep -q 'Loaded plugin: SSO Authentication' && echo yes"
r "the plugin answers at the button's address (not a 404)"     "yes" bash -c "c=\$(curl -s -o /dev/null -w '%{http_code}' localhost:8096/sso/OID/start/nextcloud); [ \"\$c\" != 404 ] && echo yes"
has "the login message has the button, with the generic text"  "/sso/OID/start/nextcloud.*Sign in with SSO" bash -c "curl -s localhost:8096/Branding/Configuration | jq -r .LoginDisclaimer"
r "a second start of Jellyfin finds the settings as declared"  "nothing to do" bash -c "sudo journalctl -u podman-jellyfin --no-pager | grep -o 'nothing to do' | tail -1"
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
# a run that stopped early (a syntax error in the part above prints no FAIL of its own) is a failure, never a pass with fewer checks
grep -q '^failed units:' "$out" || echo "FAIL the test script stopped before its end"
rm -f "$out"
