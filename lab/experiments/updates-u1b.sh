#!/usr/bin/env bash
# =============================================================================
# lab/experiments/updates-u1b.sh <days>... — phase 8 (ADR 0016), U1b: the COLD cost of an update. After updates-u1.sh: for each N, an empty store is seeded with the OLD system's closure only
# (what a machine running it would have), and the NEW system is built against that store: what is fetched (size, number of paths), what is built here (which derivations, how long).
# =============================================================================
set -uo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH
export NIX_CONFIG='experimental-features = nix-command flakes
download-attempts = 60
stalled-download-timeout = 120
connect-timeout = 20'
OUT=/root/u1out
ms() { echo $(( $(date +%s%N) / 1000000 )); }
say() { echo "$(date +%H:%M:%S) $*"; }
T=nixosConfigurations.lab.config.system.build.toplevel
for N in "$@"; do
  say "################ cold update from a system with nixpkgs $N days old"
  rm -rf /root/store-$N; mkdir -p /root/store-$N
  s=$(ms); nix copy --no-check-sigs --to "local?root=/root/store-$N" $OUT/old-$N 2>&1 | tail -n 1; say "seeded an empty store with the old closure ($(du -sh /root/store-$N | cut -f1) on disk): $(( ($(ms) - s) / 1000 )) s"
  cd /root/up-new
  nix build --store "local?root=/root/store-$N" path:.#$T --dry-run 2>&1 | grep -v "^evaluation warning" > $OUT/cold-dry-$N.txt
  grep -E "will be built|will be fetched" $OUT/cold-dry-$N.txt | sed 's#/nix/store/[a-z0-9]*-##'
  say "to BUILD here: $(sed -n '/will be built/,/will be fetched/p' $OUT/cold-dry-$N.txt | grep -c '\.drv') derivations, of which not just configuration glue: $(sed -n '/will be built/,/will be fetched/p' $OUT/cold-dry-$N.txt | grep '\.drv' | sed 's#.*/[a-z0-9]*-##; s#\.drv##' | grep -vE '^(unit-|X-Restart|etc|system-|nixos-|activate|boot|issue|dbus|rules|prometheus|tmpfiles|shutdown|options|manual|user-|nginx\.conf|nextcloud-(config|occ|app)|nix-apps|incus-ovmf|oidc)' | tr '\n' ' ')"
  s=$(ms); nix build --store "local?root=/root/store-$N" path:.#$T -o /root/store-$N-result --print-build-logs 2>&1 | grep -v "^evaluation warning" > $OUT/cold-build-$N.txt
  say "fetched $(grep -c 'copying path' $OUT/cold-build-$N.txt) paths and built $(grep -c "^building '" $OUT/cold-build-$N.txt) derivations in $(( ($(ms) - s) / 1000 )) s; error lines: $(grep -c '^error' $OUT/cold-build-$N.txt)"
  grep -E "^error" $OUT/cold-build-$N.txt | head -n 3
  say "store grew by $(( $(du -sm /root/store-$N | cut -f1) )) MiB in all; the old closure alone was $(nix path-info -S $OUT/old-$N | awk '{printf "%.0f", $2/1048576}') MiB"
  rm -rf /root/store-$N /root/store-$N-result
done
say done
