#!/usr/bin/env bash
# =============================================================================
# lab/experiments/updates-u3.sh — phase 8 (ADR 0016), U3: deploy methods and what each does when a deploy locks the admin out. Run from the WORKSTATION against the lab host-v,
# which has a small test flake in ~/dt (a host with an admin key and sshd, deployed to itself over ssh on localhost:2222).
#   a. nixos-rebuild --target-host   b. the same with `test` and a reboot   c. deploy-rs, a good deploy and a deploy that removes the admin keys (magic rollback)
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; VM="$HERE/vm.sh"
V() { "$VM" ssh host-v "$@"; }
say() { echo "$(date +%H:%M:%S) $*"; }
ENVV='export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH; export NIX_CONFIG="experimental-features = nix-command flakes
download-attempts = 60
stalled-download-timeout = 120"; cd ~/dt'
setv() { V "$ENVV; printf '{ sshPort = 2222; marker = \"%s\"; broken = %s; }\n' '$1' '$2' > variant.nix"; }
marker() { V 'cat /etc/dt-marker' 2>/dev/null || echo "(no ssh)"; }
poll_ssh() { # poll_ssh <max seconds>: prints "locked out after X s" / "back after Y s"
  local t0=$(date +%s) state=up lock=""; local deadline=$(( t0 + $1 ))
  while [ $(date +%s) -lt $deadline ]; do
    if V true >/dev/null 2>&1; then [ "$state" = down ] && { say "ssh is back after $(( $(date +%s) - lock )) s of lockout"; return 0; }; else [ "$state" = up ] && { state=down; lock=$(date +%s); say "ssh LOCKED OUT (at +$(( lock - t0 )) s)"; }; fi
    sleep 2
  done
  [ "$state" = down ] && say "still locked out after $(( $(date +%s) - lock )) s"; return 1
}
# the broken variant removes the admin keys (a realistic mistake): patch host.nix once to honour it
V 'grep -q "v.broken" ~/dt/host.nix || perl -0pi -e "s/openssh.authorizedKeys.keys = \[/openssh.authorizedKeys.keys = lib.optionals (!v.broken) [/" ~/dt/host.nix; grep -c "v.broken" ~/dt/host.nix' | sed 's/^/host.nix honours "broken": /' 
SSHO='-p 2222 -i /home/lab/.ssh/id_dt -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
want() { [[ " ${STAGES:-a c1 c2 b} " == *" $1 "* ]]; }
want a && {
say "== a. nixos-rebuild switch --target-host (a good change)"
setv a false
s=$(date +%s); V "$ENVV; NIX_SSHOPTS='$SSHO' nixos-rebuild switch --flake path:/home/lab/dt#vtest --target-host lab@localhost --sudo 2>&1 | grep -v '^evaluation warning' | tail -n 3"
say "a: $(( $(date +%s) - s )) s; marker on the host: $(marker)"
}
want c1 && {
say "== c1. deploy-rs (a good change)"
setv c false
s=$(date +%s); V "$ENVV; nix run github:serokell/deploy-rs -- --skip-checks path:/home/lab/dt#vtest 2>&1 | grep -E 'INFO|WARN|ERROR' | sed 's/^\[[^]]*\] //' | tail -n 8"
say "c1: $(( $(date +%s) - s )) s; marker on the host: $(marker)"
}
want c2 && {
say "== c2. deploy-rs, a deploy that REMOVES the admin keys (magic rollback expected)"
setv BROKEN-c2 true
V "$ENVV; sudo rm -f /tmp/dr-c2.log; sudo systemd-run --unit=drc2 --uid=lab --gid=users --collect -E HOME=/home/lab --property=StandardOutput=file:/tmp/dr-c2.log --property=StandardError=file:/tmp/dr-c2.log /run/current-system/sw/bin/bash -c 'export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:\$PATH; export NIX_CONFIG=\"experimental-features = nix-command flakes\"; cd /home/lab/dt; nix run github:serokell/deploy-rs -- --skip-checks path:/home/lab/dt#vtest'" >/dev/null 2>&1
t0=$(date +%s); poll_ssh 240
say "c2: the deploy log:"; V 'sed "s/^\[[^]]*\] //" /tmp/dr-c2.log | grep -E "INFO|WARN|ERROR" | tail -n 8'
say "c2: marker after the magic rollback: $(marker) (the broken deploy had marker BROKEN-c2)"
}
want b && {
say "== b. nixos-rebuild TEST --target-host that removes the keys, then a reboot"
setv BROKEN-b true
V "$ENVV; sudo systemd-run --unit=nrb --uid=lab --gid=users --collect -E HOME=/home/lab --property=StandardOutput=file:/tmp/nrb.log --property=StandardError=file:/tmp/nrb.log /run/current-system/sw/bin/bash -c 'export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:\$PATH; export NIX_CONFIG=\"experimental-features = nix-command flakes\"; cd /home/lab/dt; NIX_SSHOPTS=\"$SSHO\" nixos-rebuild test --flake path:/home/lab/dt#vtest --target-host lab@localhost --sudo'" >/dev/null 2>&1
sleep 45; poll_ssh 20 || true
say "b: the deploy command itself reported: $(V 'tail -n 2 /tmp/nrb.log' 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
say "b: nothing in the software can repair this; the way back is to reach the machine: here, a reboot (a hard power cycle)"
t0=$(date +%s); "$VM" stop host-v >/dev/null 2>&1; "$VM" start host-v >/dev/null 2>&1
for i in $(seq 1 60); do V true >/dev/null 2>&1 && break; sleep 3; done
say "b: ssh back $(( $(date +%s) - t0 )) s after the power cycle; marker: $(marker) (a test activation does not become the boot default)"
}
say done
