#!/usr/bin/env bash
# =============================================================================
# lab/updates-u4d.sh — phase 8 (ADR 0016), U4d: a declared, native way to have a rollback point before an update: the NixOS sanoid module with a SHORT retention on the two datasets
# that hold state. Runs INSIDE the lab host as root. Measured: that the module takes the snapshots, how many and what they hold, and that a rollback to one works.
# =============================================================================
set -uo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH
export NIX_CONFIG='experimental-features = nix-command flakes
download-attempts = 60'
ms() { echo $(( $(date +%s%N) / 1000000 )); }
say() { echo "$(date +%H:%M:%S) $*"; }
rm -rf /root/sn-test; cp -r /home/lab/nixos /root/sn-test
cat > /root/sn-test/modules/sanoid.nix <<'NIX'
{ ... }:
{
  services.sanoid = {
    enable = true;
    interval = "hourly";
    templates.short = { hourly = 24; daily = 0; weekly = 0; monthly = 0; yearly = 0; autosnap = true; autoprune = true; };
    datasets."tank/data" = { useTemplate = [ "short" ]; recursive = false; };
    datasets."tank/postgres" = { useTemplate = [ "short" ]; recursive = false; };
  };
}
NIX
sed -i 's#    ./verify.nix#    ./verify.nix\n    ./sanoid.nix#' /root/sn-test/modules/default.nix
s=$(ms); nixos-rebuild switch --flake path:/root/sn-test#lab 2>&1 | grep -v "^evaluation warning" | grep -E "error|Done" | head -n 2 | cut -c1-160; say "switch with the sanoid module: $(( ($(ms) - s) / 1000 )) s; timer: $(systemctl list-timers --no-pager | grep sanoid | awk '{print $1,$2,$3}' | head -n 1)"
rm -rf /var/cache/sanoid; s=$(ms); systemctl start sanoid.service; say "sanoid run: $(systemctl show sanoid -p Result --value) in $(( $(ms) - s )) ms"
zfs list -t snapshot -o name,used,creation | grep -E "tank/(data|postgres)" | head -n 6
say "-- a change after the snapshot, then a rollback to it"
SNAP=$(zfs list -H -t snapshot -o name -r -d1 tank/data | tail -n 1); SNAPP=$(zfs list -H -t snapshot -o name -r -d1 tank/postgres | tail -n 1)
echo "after-snapshot" > /srv/data/after-snapshot.txt; sudo -u postgres psql -d immich -qc "create table if not exists sn_marker(x text); delete from sn_marker; insert into sn_marker values ('after')" ; sync
say "before the rollback: file present: $(test -e /srv/data/after-snapshot.txt && echo yes || echo no); marker table rows: $(sudo -u postgres psql -d immich -Atc 'select count(*) from sn_marker' 2>&1)"
s=$(ms); systemctl stop nginx phpfpm-nextcloud vaultwarden podman-immich-server postgresql 2>/dev/null; zfs rollback -r $SNAP && zfs rollback -r $SNAPP; systemctl start postgresql; sleep 2; systemctl start vaultwarden phpfpm-nextcloud podman-immich-server nginx; say "rollback of both datasets to $SNAP / $SNAPP: $(( $(ms) - s )) ms until the services were started"
say "after the rollback: file present: $(test -e /srv/data/after-snapshot.txt && echo yes || echo no); marker table: $(sudo -u postgres psql -d immich -Atc 'select count(*) from sn_marker' 2>&1 | head -n 1)"
say "the space the snapshots hold after this: $(zfs list -H -o name,used -t snapshot | grep -E 'tank/(data|postgres)' | tr '\n' ' ')"
nixos-rebuild switch --flake path:/home/lab/nixos#lab 2>&1 | grep -E "error|Done" | head -n 1 | cut -c1-120; say "(the sanoid module removed again; its snapshots stay until destroyed: $(zfs list -H -t snapshot -o name | grep -c autosnap))"
for s in $(zfs list -H -t snapshot -o name | grep autosnap); do zfs destroy $s; done
say done
