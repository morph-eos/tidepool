#!/usr/bin/env bash
# =============================================================================
# lab/experiments/updates-u1.sh <days:rev>... — phase 8 (ADR 0016), U1: what does an update of nixpkgs cost after N days: what changes, what is downloaded, what is built here, how long?
# Runs INSIDE the lab host as root, with /home/lab/nixos holding the flake. For each "days:rev" it builds the system with nixpkgs pinned to that old revision (the other inputs as locked)
# and then the system with the branch's latest nixpkgs, and compares the two.
# =============================================================================
set -uo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH
export NIX_CONFIG='experimental-features = nix-command flakes
download-attempts = 60
stalled-download-timeout = 120
connect-timeout = 20'
OUT=/root/u1out; mkdir -p $OUT
ms() { echo $(( $(date +%s%N) / 1000000 )); }
say() { echo "$(date +%H:%M:%S) $*"; }
filt() { grep -v "^evaluation warning"; }
flake_at() { # flake_at <dir> <rev or "latest">
  rm -rf $1; cp -r /home/lab/nixos $1; cd $1
  if [ "$2" = latest ]; then nix flake lock --update-input nixpkgs >/dev/null 2>&1; else nix flake lock --override-input nixpkgs github:NixOS/nixpkgs/$2 >/dev/null 2>&1; fi
  jq -r '.nodes.nixpkgs.locked | "\(.rev[0:8]) \(.lastModified | strftime("%Y-%m-%d"))"' flake.lock
}
for spec in "$@"; do
  days=${spec%%:*}; rev=${spec#*:}
  say "################ nixpkgs $days days old -> latest"
  say "old nixpkgs: $(flake_at /root/up-old $rev)"; 
  say "new nixpkgs: $(flake_at /root/up-new latest)"
  T=nixosConfigurations.lab.config.system.build.toplevel
  s=$(ms); (cd /root/up-old && nix build path:.#$T -o $OUT/old-$days 2>&1 | filt | grep -E "^error" | head -n 3); say "building the OLD system (a first install onto a machine that has the new one's cousin): $(( ($(ms) - s) / 1000 )) s, closure $(nix path-info -S $OUT/old-$days | awk '{printf "%.2f GiB", $2/1073741824}')"
  say "-- the update, as a dry run: what must be fetched and what must be BUILT on this machine"
  (cd /root/up-new && nix build path:.#$T --dry-run 2>&1 | filt > $OUT/dry-$days.txt)
  grep -E "will be built|will be fetched" $OUT/dry-$days.txt | sed 's#/nix/store/[a-z0-9]*-##'
  say "derivations that would be built here: $(sed -n '/will be built/,/will be fetched/p' $OUT/dry-$days.txt | grep -c '\.drv')"
  sed -n '/will be built/,/will be fetched/p' $OUT/dry-$days.txt | grep '\.drv' | sed 's#.*/[a-z0-9]*-##; s#\.drv##' | grep -vE "^(unit-|X-Restart|etc|system-|nixos-|activate|boot|issue|dbus|rules|prometheus|tmpfiles|nixos-tmpfiles|shutdown|options|manual|user-)" | head -n 12 | tr '\n' ' '; echo
  s=$(ms); (cd /root/up-new && nix build path:.#$T -o $OUT/new-$days --print-build-logs 2>&1 | filt | grep -E "^error|fetch|copying" | tail -n 2); say "fetch and build of the NEW system: $(( ($(ms) - s) / 1000 )) s"
  nix store diff-closures $OUT/old-$days $OUT/new-$days 2>&1 | filt > $OUT/diff-$days.txt
  say "packages changed between the two: $(grep -c '→' $OUT/diff-$days.txt) (new $(grep -c 'ε →' $OUT/diff-$days.txt), gone $(grep -c '→ ∅' $OUT/diff-$days.txt)); closure old $(nix path-info -S $OUT/old-$days | awk '{printf "%.2f", $2/1073741824}') GiB, new $(nix path-info -S $OUT/new-$days | awk '{printf "%.2f", $2/1073741824}') GiB"
  grep -E "^(postgresql[-0-9.]*|nextcloud[-0-9a-z.]*|nginx|podman|linux|borgbackup|pgbackrest|openssh|zfs[-a-z]*|incus|vaultwarden|syncthing|prometheus|alertmanager|systemd|glibc|openssl|curl|vectorchord|pgvector|valkey)[:]" $OUT/diff-$days.txt | head -n 20
  say "-- how many of the changed packages are ones this server runs (a service, the kernel, a library on the network path) is judged from the list above"
done
say done
