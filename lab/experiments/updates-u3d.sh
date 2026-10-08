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
say "== git is needed on the host for git+file flakes: added to the base config first"
V "$ENVV; cd ~/dt; grep -q 'pkgs.git' host.nix || perl -0pi -e 's#system.stateVersion = \"26.05\";#environment.systemPackages = [ pkgs.git ];\n  system.stateVersion = \"26.05\";#' host.nix; sudo -E env NIX_CONFIG=\"\$NIX_CONFIG\" nixos-rebuild switch --flake path:/home/lab/dt#vtest 2>&1 | grep -E 'error|Done' | head -n 2 | cut -c1-160; which git"
say "== preparing: a git repository with the test flake, comin as an input, both pull methods switchable by variant.nix"
V "$ENVV; rm -rf ~/dt-repo; mkdir ~/dt-repo; cd ~/dt-repo; git init -q -b main; cp ~/dt/flake.nix ~/dt/host.nix .; echo eyBsaWIsIC4uLiB9OgpsZXQgdiA9IGltcG9ydCAuL3ZhcmlhbnQubml4OyBtb2RlID0gdi5tb2RlIG9yICJub25lIjsgaW4KewogIHNlcnZpY2VzLmNvbWluID0geyBlbmFibGUgPSBtb2RlID09ICJjb21pbiI7IGhvc3RuYW1lID0gInZ0ZXN0IjsgcmVtb3RlcyA9IFsgeyBuYW1lID0gIm9yaWdpbiI7IHVybCA9ICJmaWxlOi8vL2hvbWUvbGFiL2R0LXJlcG8iOyBicmFuY2hlcy5tYWluLm5hbWUgPSAibWFpbiI7IH0gXTsgfTsKICBzeXN0ZW0uYXV0b1VwZ3JhZGUgPSB7IGVuYWJsZSA9IG1vZGUgPT0gImF1dG8iOyBmbGFrZSA9ICJnaXQrZmlsZTovLy9ob21lL2xhYi9kdC1yZXBvI3Z0ZXN0IjsgZGF0ZXMgPSAiMDM6MDAiOyBmbGFncyA9IFsgIi0tbm8td3JpdGUtbG9jay1maWxlIiBdOyB9Owp9Cg== | base64 -d > pull.nix; printf '{}\n' > extra.nix; printf '{ sshPort = 2222; marker = \"base\"; broken = false; mode = \"none\"; }\n' > variant.nix
perl -0pi -e 's|deploy-rs = \{|comin = { url = \"github:nlewo/comin\"; inputs.nixpkgs.follows = \"nixpkgs\"; };\n    deploy-rs = {|; s|outputs = \{ self, nixpkgs, deploy-rs, |outputs = { self, nixpkgs, deploy-rs, comin, |; s|modules = \[ ./host.nix \]|modules = [ comin.nixosModules.comin ./host.nix ./extra.nix ./pull.nix ]|' flake.nix
git add -A; nix flake lock 2>&1 | tail -n 1; git add -A; git -c user.email=a@b -c user.name=lab commit -q -m base; git log --oneline | head -n 1" 2>&1 | tail -n 4
say "switching the host onto the repository's flake (mode none)"
V "$ENVV; sudo -E env NIX_CONFIG=\"\$NIX_CONFIG\" nixos-rebuild switch --flake git+file:///home/lab/dt-repo#vtest 2>&1 | grep -v '^evaluation warning' | grep -E 'error|Done' | head -n 3 | cut -c1-200"
say "== d. comin (polls every 60 s by default)"
commit comin comin-on
V "$ENVV; sudo -E env NIX_CONFIG=\"\$NIX_CONFIG\" nixos-rebuild switch --flake git+file:///home/lab/dt-repo#vtest 2>&1 | grep -E 'error|Done' | head -n 2 | cut -c1-160"
say "comin running: $(V 'systemctl is-active comin')"
commit comin comin-1 >/dev/null; t0=$(date +%s)
for i in $(seq 1 60); do [ "$(marker)" = comin-1 ] && break; sleep 5; done; say "d1: a good commit is live after $(( $(date +%s) - t0 )) s (marker $(marker))"
commit comin comin-bad '{ environment.etc."dt-bad".text = throw "this commit does not evaluate"; }' >/dev/null; t0=$(date +%s); sleep 150
say "d2: a commit that does not evaluate: the host kept marker $(marker); comin is $(V 'systemctl is-active comin'); units failed on the host: $(V 'systemctl --failed --no-legend | wc -l')"
say "d2: what comin logged: $(V 'sudo journalctl -u comin --no-pager -o cat --since "-3min" | grep -iE "error|fail|throw|evaluat" | head -n 3 | cut -c1-200' | tr '\n' '|')"
say "d2: comin's own metrics endpoint: $(V 'curl -s -m 3 localhost:4243/metrics 2>/dev/null | grep -cE "^comin_" ') comin_ series on :4243"
commit comin comin-2 '{}' >/dev/null; t0=$(date +%s)
for i in $(seq 1 60); do [ "$(marker)" = comin-2 ] && break; sleep 5; done; say "d3: after the repair commit the host is live again after $(( $(date +%s) - t0 )) s (marker $(marker))"
say "== e. system.autoUpgrade (here started by hand; in production a timer)"
commit auto auto-on >/dev/null
V "$ENVV; sudo -E env NIX_CONFIG=\"\$NIX_CONFIG\" nixos-rebuild switch --flake git+file:///home/lab/dt-repo#vtest 2>&1 | grep -E 'error|Done' | head -n 2 | cut -c1-160"
commit auto auto-1 >/dev/null; t0=$(date +%s); V 'sudo systemctl start nixos-upgrade.service' 2>&1 | tail -n 1
say "e1: a good commit is live after $(( $(date +%s) - t0 )) s (marker $(marker)); unit result: $(V 'systemctl show nixos-upgrade -p Result --value')"
commit auto auto-bad '{ environment.etc."dt-bad".text = throw "this commit does not evaluate"; }' >/dev/null; t0=$(date +%s); V 'sudo systemctl start nixos-upgrade.service' 2>&1 | tail -n 1
say "e2: a commit that does not evaluate: the unit ended after $(( $(date +%s) - t0 )) s with result $(V 'systemctl show nixos-upgrade -p Result --value'), marker unchanged: $(marker); the unit is in the failed state: $(V 'systemctl is-failed nixos-upgrade')  (our UnitFailed alert would fire)"
say "e2: what it logged: $(V 'sudo journalctl -u nixos-upgrade --no-pager -o cat --since "-2min" | grep -iE "error|throw" | head -n 2 | cut -c1-160' | tr '\n' '|')"
say done
