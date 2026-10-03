#!/usr/bin/env bash
# =============================================================================
# lab/deploy-u18.sh — ADR 0018: the private repository on GitHub, read over ssh with a deploy key kept as a sops secret and GitHub's host key pinned in the configuration.
# Runs INSIDE the lab host as root; /home/lab/nixos has modules/deploy.nix with `privateRepo` and the lab secrets with `deploy-key` (a lab key that GitHub does not know).
# =============================================================================
set -uo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH
export NIX_CONFIG='experimental-features = nix-command flakes
download-attempts = 60'
say() { echo "$(date +%H:%M:%S) $*"; }
cat > /home/lab/nixos/hosts/lab/deploykey-test.nix <<'N'
{ ... }: { tidepool.deploy = { enable = true; flake = "git+ssh://git@github.com/OWNER/tidepool.git#lab"; privateRepo = { }; interval = "yearly"; }; }
N
sed -i 's|  imports = \[|  imports = [ ./deploykey-test.nix|' /home/lab/nixos/hosts/lab/default.nix
nixos-rebuild test --flake path:/home/lab/nixos#lab 2>&1 | grep -E "^error|Done" | head -n 2 | cut -c1-160
say "the secret on the host: $(stat -c '%U:%G %a' /run/secrets/deploy-key); first line: $(head -n 1 /run/secrets/deploy-key)"
say "ssh uses it for github.com: $(ssh -G github.com | grep -iE '^(identityfile|identitiesonly|stricthostkeychecking) ' | tr '\n' ' ')"
say "github's key is pinned (known_hosts): $(ssh-keygen -F github.com -f /etc/ssh/ssh_known_hosts | grep -c ed25519) entry; fingerprint: $(ssh-keygen -lf /etc/ssh/ssh_known_hosts 2>/dev/null | grep -m1 ED25519 | cut -d' ' -f2)"
say "a real connection to github.com with the lab key (GitHub does not know it): $(ssh -n -T -o BatchMode=yes git@github.com 2>&1 | head -n 2 | tr '\n' ' ' | cut -c1-160)"
say "the same with a WRONG pinned host key (the configuration says another key): $(ssh -n -T -o BatchMode=yes -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=<(echo 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA') git@github.com 2>&1 | grep -E 'REMOTE HOST|verification failed' | head -n 1 | cut -c1-120)"
say "the deploy service reads the key through root's ssh: PATH of the unit has ssh: $(systemctl cat nixos-upgrade.service | grep -c 'openssh')"
rm -f /home/lab/nixos/hosts/lab/deploykey-test.nix; sed -i 's|  imports = \[ ./deploykey-test.nix|  imports = [|' /home/lab/nixos/hosts/lab/default.nix
say done
