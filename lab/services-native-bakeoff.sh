#!/usr/bin/env bash
# =============================================================================
# lab/services-native-bakeoff.sh — the services through their NixOS modules (ADR 0011). Runs INSIDE the lab VM, as root, with nginx-simple.nix and native.nix deployed. Lab scaffolding.
#   S1 each service answers through the proxy over HTTPS   S2 what each one uses (memory, database)   S3 the systemd isolation of each unit (systemd-analyze security)
# =============================================================================
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH
say() { printf '  %s\n' "$*"; }
curl -s --cacert /etc/ssl/certs/ca-certificates.crt https://localhost:15000/roots/0 > /tmp/pebble-root.pem
curl -s --cacert /etc/ssl/certs/ca-certificates.crt https://localhost:15000/intermediates/0 >> /tmp/pebble-root.pem
C="curl -s --max-time 20 --cacert /tmp/pebble-root.pem"
echo "== services through their NixOS modules"
r=$($C https://cloud.lab.test/status.php | jq -c '{installed,version:.versionstring}' 2>&1); say "S1 Nextcloud: $r; database: $(sudo -u nextcloud nextcloud-occ config:system:get dbtype 2>&1), cache: $(sudo -u nextcloud nextcloud-occ config:system:get memcache.distributed 2>&1 | sed 's/.*\\//')"
r=$($C -o /dev/null -w '%{http_code}' https://vault.lab.test/alive); say "S1 Vaultwarden: /alive http=$r; $($C https://vault.lab.test/api/config | jq -c '{version,environment:.environment.vault}' 2>&1 | cut -c1-120); database: $(journalctl -u vaultwarden -b --no-pager | grep -ioE 'postgres[a-z]*' | head -n 1)"
r=$($C -o /dev/null -w '%{http_code}' https://sync.lab.test/rest/noauth/health); say "S1 Syncthing GUI behind the proxy: /rest/noauth/health http=$r; the sync port 22000 listens: $(ss -ltn | grep -c ':22000 ')"
r=$($C -u lab:lab-only-dav-password -X PROPFIND -H 'Depth: 0' -o /dev/null -w '%{http_code}' https://dav.lab.test/); say "S1 WebDAV: PROPFIND with the right password http=$r; with a wrong one http=$($C -u lab:wrong -X PROPFIND -H 'Depth: 0' -o /dev/null -w '%{http_code}' https://dav.lab.test/)"
say "S1 smartd: $(smartd --version 2>&1 | head -n 1 | cut -c1-60); the module refused an empty device list when first configured"
echo "-- S2 memory in use (MiB) and unit"
for u in phpfpm-nextcloud nginx postgresql vaultwarden syncthing webdav redis-nextcloud; do
    m=$(systemctl show $u -p MemoryCurrent --value 2>/dev/null); [ "$m" != "[not set]" ] && [ -n "$m" ] && printf '    %-22s %6d MiB\n' "$u" $(( m / 1048576 ))
done
echo "-- S3 systemd exposure (lower is better; 'UNSAFE' above 6)"
for u in phpfpm-nextcloud nginx postgresql vaultwarden syncthing webdav; do
    printf '    %-22s %s\n' "$u" "$(systemd-analyze security $u.service --no-pager 2>/dev/null | tail -n 1 | sed 's/→ Overall exposure level for //; s/\x1b\[[0-9;]*m//g' | cut -c1-70)"
done
