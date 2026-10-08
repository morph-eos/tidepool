#!/usr/bin/env bash
# =============================================================================
# lab/experiments/majors-u15-nextcloud.sh — ADR 0017 (the owner asked "can we already move Nextcloud and PostgreSQL?"): Nextcloud 33 -> 34 -> 35 on the lab host's data, one major at a time
# (the module refuses to skip one). Runs INSIDE the lab host as root; /home/lab/nixos is the flake (modules/services.nix names nextcloud33 twice: package and extraApps).
# =============================================================================
set -uo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH
export NIX_CONFIG='experimental-features = nix-command flakes
download-attempts = 60'
say() { echo "$(date +%H:%M:%S) $*"; }
occ() { sudo -u nextcloud nextcloud-occ "$@" 2>&1; }
state() {
  say "  version: $(occ status | grep -E 'version:' | head -1 | tr -s ' ')   oidc: $(occ app:list | grep -E '^  - oidc' | head -1 | tr -s ' ')   disabled apps: $(occ app:list | sed -n '/Disabled/,$p' | grep -c '^  - ')"
  say "  the test file: $(sudo cat /srv/data/nextcloud/data/root/files/major-test.txt 2>&1 | head -c 40)   status.php over nginx: $(curl -sk -m 10 --resolve cloud.lab.test:443:10.0.2.15 https://cloud.lab.test/status.php | head -c 120)"
  say "  integrity: $(occ integrity:check-core 2>&1 | head -n 2 | tr '\n' ' ')   files:scan: $(occ files:scan --all 2>&1 | tail -n 4 | tr '\n' ' ' | cut -c1-110)"
}
say "== before (the lab's Nextcloud, nixos-26.05 lock)"
mkdir -p /srv/data/nextcloud/data/root/files; echo "survives the majors" > /srv/data/nextcloud/data/root/files/major-test.txt; chown nextcloud:nextcloud /srv/data/nextcloud/data/root/files/major-test.txt
occ files:scan root >/dev/null; state
for n in 34 35; do
  prev=$((n-1))
  sed -i "s/nextcloud${prev}/nextcloud${n}/g" /home/lab/nixos/modules/services.nix
  say "== switching to Nextcloud $n"
  s=$(date +%s); nixos-rebuild test --flake path:/home/lab/nixos#lab 2>&1 | grep -v "^evaluation warning" | grep -E "error|Done|failed|refus|downgrad" | head -n 4 | cut -c1-200
  say "  rebuild and switch: $(( $(date +%s) - s )) s; nextcloud-update-db: $(systemctl show nextcloud-update-db -p Result --value) ($(journalctl -u nextcloud-update-db --no-pager -o cat | grep -ciE 'update|upgrade') log lines on update/upgrade); failed units: $(systemctl --failed --no-legend | tr -s ' ' | cut -d' ' -f2 | tr '\n' ' ')"
  sleep 10; state
done
say done
