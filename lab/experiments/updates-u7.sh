#!/usr/bin/env bash
# =============================================================================
# lab/experiments/updates-u7.sh — phase 8 (ADR 0016), U7 and U9: (7) what a clean CI runner would need to run `nix flake check` on both hosts: time, download, disk, memory;
# (9) what the NEXT NixOS release would ask of this configuration, tried against nixos-unstable (26.11 is not branched yet). Runs INSIDE the lab host as root; /home/lab/nixos is the flake.
# =============================================================================
set -uo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH
export NIX_CONFIG='experimental-features = nix-command flakes
download-attempts = 60
stalled-download-timeout = 120
connect-timeout = 20'
ms() { echo $(( $(date +%s%N) / 1000000 )); }
say() { echo "$(date +%H:%M:%S) $*"; }
filt() { grep -v "^evaluation warning"; }
rm -rf /root/ci; cp -r /home/lab/nixos /root/ci; cd /root/ci
say "== 7a. the two hosts' closures"
for h in lab tidepool; do nix build path:.#nixosConfigurations.$h.config.system.build.toplevel -o /root/ci-$h 2>&1 | filt | grep -E "^error" | head -n 2; done
say "lab: $(nix path-info -S /root/ci-lab | awk '{printf "%.2f GiB", $2/1073741824}'); tidepool (the example host): $(nix path-info -S /root/ci-tidepool | awk '{printf "%.2f GiB", $2/1073741824}')"
say "both together (shared paths counted once): $(nix path-info --json -r /root/ci-lab /root/ci-tidepool 2>/dev/null | jq -r 'if type=="array" then (map({(.path):.narSize})|add|add) else ([.[].narSize]|add) end' | awk '{printf "%.2f GiB", $1/1073741824}')"
say "== 7b. a clean runner: nix flake check against an EMPTY store (everything fetched), peak memory by systemd's accounting"
rm -rf /root/store-ci; mkdir -p /root/store-ci
systemd-run --wait --collect --quiet -p MemoryAccounting=yes -p CPUAccounting=yes -E HOME=/root -E NIX_CONFIG="$NIX_CONFIG" -E PATH=$PATH -p WorkingDirectory=/root/ci \
  /run/current-system/sw/bin/bash -c 's=$(date +%s%N); nix flake check --store "local?root=/root/store-ci" path:. 2>&1 | grep -v "^evaluation warning" | tail -n 3; echo "wall: $(( ($(date +%s%N) - s) / 1000000000 )) s"' 2>&1 | grep -E "checks|wall|rror|Memory peak|CPU time|Finished|Consumed"
say "disk used by that clean store: $(du -sm /root/store-ci | cut -f1) MiB (a hosted runner has 14 GB of SSD, the larger part of it free)"
rm -rf /root/store-ci
say "== 7c. evaluation only (nix flake check --no-build): time and peak memory"
systemd-run --wait --collect --quiet -p MemoryAccounting=yes -E HOME=/root -E NIX_CONFIG="$NIX_CONFIG" -E PATH=$PATH -p WorkingDirectory=/root/ci \
  /run/current-system/sw/bin/bash -c 's=$(date +%s%N); nix flake check --no-build path:. 2>&1 | grep -v "^evaluation warning" | tail -n 2; echo "wall: $(( ($(date +%s%N) - s) / 1000000000 )) s"' 2>&1 | grep -E "checks|wall|rror|Memory peak"
say "== 9. the next release: the same configuration against nixos-unstable (26.11 is branched at the end of November)"
rm -rf /root/un; cp -r /home/lab/nixos /root/un; cd /root/un
nix flake lock --override-input nixpkgs github:NixOS/nixpkgs/nixos-unstable 2>&1 | grep -E "Updated|Added|error" | head -n 3 | cut -c1-200
s=$(ms); nix eval --raw path:.#nixosConfigurations.lab.config.system.build.toplevel.drvPath > /root/un-eval.txt 2> /root/un-err.txt; rc=$?
say "evaluation against unstable: exit $rc in $(( ($(ms) - s) / 1000 )) s; warnings: $(grep -c '^evaluation warning' /root/un-err.txt), errors: $(grep -c '^error' /root/un-err.txt)"
grep '^evaluation warning' /root/un-err.txt | sort | uniq -c | sort -rn | cut -c1-230 | head -n 12
grep -A6 '^error' /root/un-err.txt | head -n 12 | cut -c1-230
say "and the current stable, for comparison: warnings $(cd /root/ci && nix eval --raw path:.#nixosConfigurations.lab.config.system.build.toplevel.drvPath 2>&1 >/dev/null | grep -c '^evaluation warning')"
if [ $rc = 0 ]; then nix build --dry-run "path:.#nixosConfigurations.lab.config.system.build.toplevel" 2>&1 | filt | grep -E "will be built|will be fetched" | sed 's#/nix/store/[a-z0-9]*-##'; fi
say done
