#!/usr/bin/env bash
# =============================================================================
# lab/experiments/renovate-u19.sh — ADR 0018: Renovate on the server through `services.renovate` (modules/renovate.nix). Runs INSIDE the lab host as root; /home/lab/nixos is the flake with
# the module and a dummy token in the lab secrets. The token is not valid: the point is the unit (sandbox, PATH, memory), the failure that a lapsed token causes, and Nix under the unit's user.
# =============================================================================
set -uo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH
export NIX_CONFIG='experimental-features = nix-command flakes
download-attempts = 60'
ms() { echo $(( $(date +%s%N) / 1000000 )); }
say() { echo "$(date +%H:%M:%S) $*"; }
cat > /home/lab/nixos/hosts/lab/renovate-test.nix <<'N'
{ ... }: { tidepool.renovate = { enable = true; repositories = [ "nobody/nothing" ]; }; }
N
sed -i 's|  imports = \[|  imports = [ ./renovate-test.nix|' /home/lab/nixos/hosts/lab/default.nix
sed -i "0,/\.\/renovate-test\.nix \.\/renovate-test\.nix/s//.\/renovate-test.nix/" /home/lab/nixos/hosts/lab/default.nix
s=$(ms); nixos-rebuild test --flake path:/home/lab/nixos#lab 2>&1 | grep -v "^evaluation warning" | tail -n 4 | cut -c1-200; say "switch: $(( ($(ms) - s) / 1000 )) s (the configuration was validated by renovate-config-validator at build time)"
say "timer: $(systemctl list-timers renovate.timer --no-legend | tr -s ' ' | cut -d' ' -f1-4)"
say "unit: DynamicUser=$(systemctl show renovate -p DynamicUser --value) Type=$(systemctl show renovate -p Type --value); PATH has nix: $(systemctl show renovate -p Environment --value | grep -c 'nix-[0-9]'), git: $(systemctl show renovate -p Environment --value | grep -c 'git-[0-9]')"
say "the token reaches the unit as a credential, not in the environment: $(systemctl show renovate -p LoadCredential --value | cut -c1-60); in the unit file: $(systemctl cat renovate | grep -c 'ghp_')"
say "the generated config: $(systemctl cat renovate | grep -oE 'RENOVATE_CONFIG_FILE=[^ ]+' | head -1 | cut -c1-90)"
CF=$(systemctl cat renovate | grep -oE 'RENOVATE_CONFIG_FILE=[^ "]+' | head -1 | cut -d= -f2); [ -n "$CF" ] && head -c 400 "$CF"; echo
say "== the run with an invalid token"
t0=$(ms); systemctl start --no-block renovate; sleep 3
for i in $(seq 1 120); do systemctl is-active -q renovate || break; sleep 2; done
say "result: $(systemctl show renovate -p Result --value), $(( ($(ms) - t0) / 1000 )) s; $(journalctl -u renovate --no-pager -o cat | grep -E 'Consumed' | tail -1 | grep -oE 'Consumed.*' | cut -c1-150)"
journalctl -u renovate --no-pager -o cat | grep -iE "bad credentials|401|token|Authentication" | head -n 3 | cut -c1-170
say "Prometheus alert for it (the rule waits 5 minutes): waiting"
for i in $(seq 1 60); do curl -s localhost:9093/api/v2/alerts | grep -q 'renovate.service' && break; sleep 10; done
say "alert on renovate.service in Alertmanager after $(( ($(ms) - t0) / 1000 )) s: $(curl -s localhost:9093/api/v2/alerts | grep -c 'renovate.service')"
say "== nix under a dynamic user"
P=path:/home/lab/nixos#nixosConfigurations.lab.pkgs; NIX=$(nix build --no-link --print-out-paths $P.nix | tail -n 1); GIT=$(nix build --no-link --print-out-paths $P.git | tail -n 1)
rm -rf /srv/rn-stage; mkdir -p /srv/rn-stage; cd /home/lab/nixos && tar cf - flake.nix flake.lock modules hosts secrets keys vars | tar xf - -C /srv/rn-stage; chmod -R a+rX /srv/rn-stage
systemd-run --unit=rn-nix2 --wait --collect -q -p DynamicUser=yes -p StateDirectory=rn2 -p ProtectSystem=strict -p ProtectHome=yes -p PrivateTmp=yes -p NoNewPrivileges=yes -p WorkingDirectory=/var/lib/rn2 -E HOME=/var/lib/rn2 -E PATH=$NIX/bin:$GIT/bin:/run/current-system/sw/bin \
  /run/current-system/sw/bin/bash -c 'cp -r /srv/rn-stage work; cd work; echo "user: $(id -un); before: $(grep -o "\"rev\": \"[0-9a-f]\{8\}" flake.lock | head -1)"; s=$(date +%s); nix flake update 2>&1 | grep -E "Updated|error" | head -n 4; echo "nix flake update took $(( $(date +%s) - s )) s; after: $(grep -o "\"rev\": \"[0-9a-f]\{8\}" flake.lock | head -1)"' < /dev/null > /dev/null 2>&1
journalctl -u rn-nix2 --no-pager -o cat | grep -E "user:|Updated|error|took" | head -n 8 | cut -c1-170
say done
