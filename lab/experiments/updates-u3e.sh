#!/usr/bin/env bash
# =============================================================================
# lab/experiments/updates-u3d.sh — phase 8 (ADR 0016), U3 d and e: the two PULL methods. Run from the WORKSTATION against the lab host-v, which has the small test flake of updates-u3.sh in ~/dt.
#   d. comin: the host polls a git repository and applies what it finds       e. system.autoUpgrade: a timer runs nixos-rebuild against the repository
# For each: a good commit (how long until it is live), a commit that does not even evaluate (what happens, would the alerts see it), and where it logs.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; VM="$HERE/vm.sh"
V() { "$VM" ssh host-v "$@"; }
say() { echo "$(date +%H:%M:%S) $*"; }
ENVV='export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH; export NIX_CONFIG="experimental-features = nix-command flakes
download-attempts = 60
stalled-download-timeout = 120"'
marker() { V 'cat /etc/dt-marker' 2>/dev/null || echo "(no ssh)"; }
commit() { # commit <mode> <marker> [extra nix line]
  set -- "$1" "$2" "${3:-}"; [ -n "$3" ] || set -- "$1" "$2" "{}"
  V "$ENVV; cd ~/dt-repo; printf '{ sshPort = 2222; marker = \"%s\"; broken = false; mode = \"%s\"; }\n' '$2' '$1' > variant.nix; printf '%s\n' '$3' > extra.nix; git add -A; git -c user.email=a@b -c user.name=lab commit -q -m '$2' --allow-empty; git log --oneline | head -n 1"; }
say "== e. system.autoUpgrade (here started by hand; in production a timer); root must be allowed to read the repository owned by the admin (git safe.directory), a lab detail"
V "sudo git config --system --add safe.directory '*'"
commit auto auto-on >/dev/null
V "$ENVV; sudo -E env NIX_CONFIG=\"\$NIX_CONFIG\" nixos-rebuild switch --flake git+file:///home/lab/dt-repo#vtest 2>&1 | grep -E 'error|Done' | head -n 2 | cut -c1-160"
commit auto auto-1 >/dev/null; t0=$(date +%s); V 'sudo systemctl start nixos-upgrade.service' 2>&1 | tail -n 1
say "e1: a good commit is live after $(( $(date +%s) - t0 )) s (marker $(marker)); unit result: $(V 'systemctl show nixos-upgrade -p Result --value')"
commit auto auto-bad '{ environment.etc."dt-bad".text = throw "this commit does not evaluate"; }' >/dev/null; t0=$(date +%s); V 'sudo systemctl start nixos-upgrade.service' 2>&1 | tail -n 1
say "e2: a commit that does not evaluate: the unit ended after $(( $(date +%s) - t0 )) s with result $(V 'systemctl show nixos-upgrade -p Result --value'), marker unchanged: $(marker); the unit is in the failed state: $(V 'systemctl is-failed nixos-upgrade')  (our UnitFailed alert would fire)"
say "e2: what it logged: $(V 'sudo journalctl -u nixos-upgrade --no-pager -o cat --since "-2min" | grep -iE "error|throw" | head -n 2 | cut -c1-160' | tr '\n' '|')"
say done
