#!/usr/bin/env bash
# =============================================================================
# lab/services-extra-bakeoff.sh — WebDAV for a backup app (two ways) and Nextcloud as the OpenID provider (ADR 0011). Runs INSIDE the lab VM, as root. Lab scaffolding.
#   W: a Seedvault-like sequence (MKCOL, PUT, PROPFIND, MOVE, GET, DELETE, a 2 GB PUT) against the webdav module (dav.lab.test) and against nginx (dav2.lab.test)
#   O: the oidc app declared, a client created, the discovery document, Vaultwarden's SSO
# =============================================================================
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH
say() { printf '  %s\n' "$*"; }
curl -s --cacert /etc/ssl/certs/ca-certificates.crt https://localhost:15000/roots/0 > /tmp/pebble-root.pem
curl -s --cacert /etc/ssl/certs/ca-certificates.crt https://localhost:15000/intermediates/0 >> /tmp/pebble-root.pem
C="curl -s --max-time 120 --cacert /tmp/pebble-root.pem -u lab:lab-only-dav-password"
head -c 5242880 /dev/urandom > /tmp/chunk.bin; truncate -s 2G /tmp/big.bin
echo "== WebDAV, a Seedvault-like sequence"
for h in dav.lab.test dav2.lab.test; do
    B=https://$h
    o=$($C -X OPTIONS -i $B/ | grep -iE '^(dav|allow):' | tr -d '\r' | tr '\n' ' ' | cut -c1-110)
    m=$($C -X MKCOL -o /dev/null -w '%{http_code}' $B/sv/)
    p=$($C -T /tmp/chunk.bin -o /dev/null -w '%{http_code}' $B/sv/chunk1)
    f=$($C -X PROPFIND -H 'Depth: 1' -o /tmp/pf.xml -w '%{http_code}' $B/sv/); n=$(grep -c "chunk1" /tmp/pf.xml)
    v=$($C -X MOVE -H "Destination: $B/sv/chunk2" -o /dev/null -w '%{http_code}' $B/sv/chunk1)
    g=$($C $B/sv/chunk2 | wc -c)
    d=$($C -X DELETE -o /dev/null -w '%{http_code}' $B/sv/chunk2)
    t0=$(date +%s); b=$($C -T /tmp/big.bin -o /dev/null -w '%{http_code}' $B/sv/big); t1=$(( $(date +%s) - t0 ))
    w=$(curl -s --cacert /tmp/pebble-root.pem -u lab:wrong -X PROPFIND -H 'Depth: 0' -o /dev/null -w '%{http_code}' $B/)
    say "$h: OPTIONS [$o]"
    say "$h: MKCOL $m, PUT 5 MB $p, PROPFIND $f (lists chunk1: $n), MOVE $v, GET returns $g bytes, DELETE $d, PUT 2 GB $b in ${t1}s, wrong password $w"
    $C -X DELETE -o /dev/null $B/sv/big; $C -X DELETE -o /dev/null $B/sv/
done
echo "-- systemd exposure (lower is better)"
for u in webdav nginx; do printf '    %-10s %s\n' "$u" "$(systemd-analyze security $u.service --no-pager 2>/dev/null | tail -n 1 | sed 's/→ Overall exposure level for //; s/\x1b\[[0-9;]*m//g' | cut -c1-60)"; done
rm -f /tmp/big.bin /tmp/chunk.bin

echo "== Nextcloud as the OpenID provider"
occ() { sudo -u nextcloud nextcloud-occ "$@"; }
say "O1: the oidc app: $(occ app:list 2>/dev/null | grep -A0 -E '^\s+- oidc:' | tr -d ' ')   (enabled apps list contains it: $(occ app:list 2>/dev/null | sed -n '/Enabled/,/Disabled/p' | grep -c ' oidc:'))"
say "O2: the command to create a client: $(occ list oidc 2>/dev/null | grep -E 'oidc:create' | tr -s ' ' | cut -c1-120)"
occ oidc:remove vaultwarden-lab >/dev/null 2>&1
out=$(occ oidc:create "Vaultwarden" "https://vault.lab.test/identity/connect/oidc-signin" --client_id=vaultwarden-lab --client_secret=lab-only-sso-secret --type=confidential --flow=code 2>&1 | head -c 300 | tr '\n' ' ')
say "O2: a client created by a command: ${out}"
say "O2: the clients the app knows: $(occ oidc:list 2>&1 | head -c 200 | tr '\n' ' ')"
for u in "https://cloud.lab.test/.well-known/openid-configuration" "https://cloud.lab.test/index.php/apps/oidc/openid-configuration"; do
    r=$($C -o /tmp/disc.json -w '%{http_code}' "$u"); say "O3: discovery at ${u#https://cloud.lab.test}: http=$r $( [ "$r" = 200 ] && jq -c '{issuer,authorization_endpoint,token_endpoint,jwks_uri}' /tmp/disc.json | cut -c1-230)"
done
say "O4: Vaultwarden's configuration reports SSO: $($C https://vault.lab.test/api/config | jq -c '{sso: .sso // .ssoLogin // null, feature: (.featureStates // {} | keys | map(select(test("sso"; "i"))))}' 2>&1 | cut -c1-160)"
