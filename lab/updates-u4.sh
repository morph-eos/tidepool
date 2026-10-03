#!/usr/bin/env bash
# =============================================================================
# lab/updates-u4.sh — phase 8 (ADR 0016), U4: updates of services that keep STATE, and what can be undone. Runs INSIDE the lab host (the integrated host with the drill's data), as root.
#   a. Immich: an older server image started on a database the newer one created
#   b. PostgreSQL: how long a restart (a minor update) silences each service
#   c. a major Nextcloud update (33 -> 34): a snapshot of the two ZFS datasets first, the update, the rollback of the system generation (does it work?), then the ZFS rollback
# =============================================================================
set -uo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH
export NIX_CONFIG='experimental-features = nix-command flakes
download-attempts = 60
stalled-download-timeout = 120'
ms() { echo $(( $(date +%s%N) / 1000000 )); }
say() { echo "$(date +%H:%M:%S) $*"; }
STAGES=${STAGES:-a b c}; want() { [[ " $STAGES " == *" $1 "* ]]; }
IM=http://127.0.0.1:2283
curlok() { curl -sk -m 2 -o /dev/null -w '%{http_code}' --resolve "$1:443:127.0.0.1" "https://$1$2" | grep -qE "^(200|301|302|401)$"; }
say "== baseline: the host back on the flake's own lock (the earlier tests left it on a newer nixpkgs through switch-to-configuration test)"
nixos-rebuild switch --flake path:/home/lab/nixos#lab 2>&1 | grep -v '^evaluation warning' | grep -E 'error|Done' | head -n 2 | cut -c1-160
sleep 20
want a && {
say "== a. Immich: the v0 server image (v3.2.1) started on the database that v3.2.4 created"
systemctl stop podman-immich-server; sleep 2
podman pull -q ghcr.io/immich-app/immich-server:v3.2.1 >/dev/null 2>&1; say "pulled: $(podman image exists ghcr.io/immich-app/immich-server:v3.2.1 && echo yes || echo no)"
podman rm -f immich-old >/dev/null 2>&1
podman run -d --name immich-old --network=host -e DB_HOSTNAME=/run/postgresql -e DB_USERNAME=postgres -e DB_PASSWORD=x -e DB_DATABASE_NAME=immich -e REDIS_HOSTNAME=127.0.0.1 -v /srv/data/immich/upload:/data -v /run/postgresql:/run/postgresql ghcr.io/immich-app/immich-server:v3.2.1 >/dev/null 2>&1
s=$(ms); ok=no; for i in $(seq 1 60); do curl -sf -m 2 $IM/api/server/ping >/dev/null 2>&1 && { ok=yes; break; }; sleep 2; done
say "the OLD server answers its ping: $ok (after $(( ($(ms) - s) / 1000 )) s)"
podman logs immich-old 2>&1 | grep -iE "error|migrat|newer|downgrad|incompat|fatal|exception" | head -n 6 | cut -c1-230
podman rm -f immich-old >/dev/null 2>&1; systemctl start podman-immich-server; for i in $(seq 1 60); do curl -sf -m 2 $IM/api/server/ping >/dev/null 2>&1 && break; sleep 2; done; say "the pinned (new) server is back: $(curl -s $IM/api/server/ping)"
}
want b && {
say "== b. PostgreSQL restart (what a minor update does)"
rm -f /tmp/probe.stop /tmp/probe.log
probe() { local n=$1; shift; local last=""; while [ ! -e /tmp/probe.stop ]; do if "$@" >/dev/null 2>&1; then c=up; else c=down; fi; [ "$c" != "$last" ] && echo "$(( $(date +%s%N) / 1000000 )) $n $c" >> /tmp/probe.log; last=$c; sleep 0.2; done; }
probe vaultwarden curlok vault.lab.test /alive & probe nextcloud curlok cloud.lab.test /status.php & probe immich curlok photos.lab.test /api/server/ping & probe postgres pg_isready -q -h /run/postgresql &
sleep 3; s=$(ms); systemctl restart postgresql; say "systemctl restart postgresql returned after $(( $(ms) - s )) ms"; sleep 40; touch /tmp/probe.stop; sleep 1; wait
python3 - <<'PY' 2>/dev/null || cat /tmp/probe.log
import collections
ev=collections.defaultdict(list)
for l in open("/tmp/probe.log"):
    t,n,c=l.split(); ev[n].append((int(t),c))
for n,e in ev.items():
    outs=[];d=None
    for t,c in e:
        if c=="down" and d is None: d=t
        if c=="up" and d is not None: outs.append(t-d); d=None
    if d is not None: outs.append(-1)
    print(f"  {n:12s} silences: {[f'{o/1000:.1f} s' if o>=0 else 'STILL DOWN' for o in outs] or 'none'}")
PY
say "units failed after the restart: $(systemctl --failed --no-legend | wc -l)"
}
want c && {
say "== c. a major Nextcloud update (33 -> 34) with a ZFS snapshot first"
S=$(ms); say "Nextcloud now: $(curl -sk --resolve cloud.lab.test:443:127.0.0.1 https://cloud.lab.test/status.php | jq -c '{installed,version}')"
rm -rf /root/nc-test; cp -r /home/lab/nixos /root/nc-test
cat > /root/nc-test/modules/nc34.nix <<'NIX'
{ lib, pkgs, ... }:
{
  services.nextcloud.package = lib.mkForce pkgs.nextcloud34;
  services.nextcloud.extraApps = lib.mkForce { inherit (pkgs.nextcloud34Packages.apps) oidc; };
}
NIX
sed -i 's#    ./verify.nix#    ./verify.nix\n    ./nc34.nix#' /root/nc-test/modules/default.nix
s=$(ms); zfs snapshot tank/data@pre-update tank/postgres@pre-update; say "snapshot of tank/data and tank/postgres (one transaction): $(( $(ms) - s )) ms; space they hold now: $(zfs list -H -o used -t snapshot | tr '\n' ' ')"
cp -r /nix/var/nix/profiles/system /tmp/ 2>/dev/null; GEN_BEFORE=$(readlink /run/current-system)
s=$(ms); nixos-rebuild switch --flake path:/root/nc-test#lab 2>&1 | grep -v "^evaluation warning" | grep -E "error|restarting|Done|failed" | head -n 8 | cut -c1-200; say "switch to Nextcloud 34: $(( ($(ms) - s) / 1000 )) s"
for i in $(seq 1 60); do curl -sk -m 3 --resolve cloud.lab.test:443:127.0.0.1 https://cloud.lab.test/status.php | jq -e '.installed==true and .maintenance==false' >/dev/null 2>&1 && break; sleep 3; done
say "Nextcloud after the update: $(curl -sk --resolve cloud.lab.test:443:127.0.0.1 https://cloud.lab.test/status.php | jq -c '{installed,maintenance,version}'); setup unit: $(systemctl is-active nextcloud-setup)"
say "-- going BACK to the previous system generation (what 'rollback' means on NixOS)"
s=$(ms); nix-env -p /nix/var/nix/profiles/system --rollback 2>&1 | tail -n 1; /nix/var/nix/profiles/system/bin/switch-to-configuration switch 2>&1 | grep -E "error|rror|Done|failed|restarting|warning" | head -n 6 | cut -c1-220; say "rollback of the system generation took $(( ($(ms) - s) / 1000 )) s (this is what nixos-rebuild --rollback does)"
sleep 15; say "Nextcloud after the rollback of the system: $(curl -sk -m 5 --resolve cloud.lab.test:443:127.0.0.1 https://cloud.lab.test/status.php | head -c 120); nextcloud-setup: $(systemctl is-active nextcloud-setup); php-fpm: $(systemctl is-active phpfpm-nextcloud)"
journalctl -u nextcloud-setup --no-pager -o cat --since "-3min" | grep -iE "downgrad|newer|error|not supported|can not|cannot" | head -n 3 | cut -c1-220
say "-- the way back with the data: stop the services, roll the two datasets back to the snapshot, start"
s=$(ms); systemctl stop nginx phpfpm-nextcloud nextcloud-cron.timer nextcloud-setup nextcloud-update-db postgresql 2>/dev/null
zfs rollback -r tank/data@pre-update && zfs rollback -r tank/postgres@pre-update; say "zfs rollback of both datasets: $(( $(ms) - s )) ms"
systemctl start postgresql; sleep 3; systemctl start nextcloud-setup phpfpm-nextcloud nginx nextcloud-cron.timer 2>&1 | tail -n 2
for i in $(seq 1 60); do curl -sk -m 3 --resolve cloud.lab.test:443:127.0.0.1 https://cloud.lab.test/status.php | jq -e '.installed==true and .maintenance==false' >/dev/null 2>&1 && break; sleep 3; done
say "total from the start of the recovery to Nextcloud answering again: $(( ($(ms) - s) / 1000 )) s; Nextcloud: $(curl -sk --resolve cloud.lab.test:443:127.0.0.1 https://cloud.lab.test/status.php | jq -c '{installed,version}'); files: $(curl -sk -u root:$(cat /run/secrets/nextcloud-admin-pass) -X PROPFIND -H 'Depth: 1' --resolve cloud.lab.test:443:127.0.0.1 https://cloud.lab.test/remote.php/dav/files/root/ | grep -o 'nc-[ab][0-9].txt' | sort -u | wc -l) of the 5 test files"
zfs destroy tank/data@pre-update; zfs destroy tank/postgres@pre-update; say "snapshots removed"
}
say done
