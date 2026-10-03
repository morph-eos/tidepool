#!/usr/bin/env bash
# =============================================================================
# lab/deploy-u17.sh — ADR 0018, after deploy-u16.sh: (a) the deploy key: the server reads the PRIVATE repository over ssh with a key that can do nothing else, as it would from GitHub;
# (b) `--override-input` instead of the deprecated `--update-input`. Runs INSIDE the lab host as root; /home/lab/nixos has modules/deploy.nix with `tidepool.deploy.inputs`.
# =============================================================================
set -uo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH
export NIX_CONFIG='experimental-features = nix-command flakes
download-attempts = 60'
GITBIN=$(nix build --no-link --print-out-paths path:/home/lab/nixos#nixosConfigurations.lab.pkgs.git | head -n 1)/bin; export PATH=$GITBIN:$PATH
ms() { echo $(( $(date +%s%N) / 1000000 )); }
say() { echo "$(date +%H:%M:%S) $*"; }
G="git -c user.email=lab@lab.test -c user.name=lab"
marker() { cat /etc/tidepool-marker 2>/dev/null || echo none; }
say "== (a) the deploy key"
rm -rf /root/.ssh/dk* /srv/git/priv-ssh.git; mkdir -p /root/.ssh; chmod 700 /root/.ssh
ssh-keygen -q -t ed25519 -N '' -C tidepool-deploy -f /root/.ssh/dk
git clone -q --bare /srv/git/priv.git /srv/git/priv-ssh.git; chown -R lab /srv/git/priv-ssh.git
mkdir -p /home/lab/.ssh; chown lab /home/lab/.ssh; chmod 700 /home/lab/.ssh; : > /home/lab/.ssh/authorized_keys; chown lab /home/lab/.ssh/authorized_keys   # sshd reads this file next to the one NixOS generates; only the deploy key is put here
echo "restrict,command=\"$GITBIN/git-shell -c \\\"\$SSH_ORIGINAL_COMMAND\\\"\" $(cat /root/.ssh/dk.pub)" >> /home/lab/.ssh/authorized_keys
HK=$(ssh-keyscan -p 2222 localhost 2>/dev/null | grep ed25519 | head -n 1 | cut -d' ' -f2-)
printf 'Host privrepo\n  HostName localhost\n  Port 2222\n  User lab\n  IdentityFile /root/.ssh/dk\n  IdentitiesOnly yes\n  StrictHostKeyChecking yes\n  UserKnownHostsFile /root/.ssh/kh\n' > /root/.ssh/config
echo "[localhost]:2222 $HK" > /root/.ssh/kh
R=git+ssh://privrepo/srv/git/priv-ssh.git
say "fetch the flake over ssh with the deploy key: $(nix flake metadata $R --refresh 2>&1 | grep -E 'Revision|error' | head -n 2 | tr '\n' ' ' | cut -c1-140)"
say "the key may run a shell command? $(ssh -n privrepo 'echo owned' 2>&1 | head -n 1 | cut -c1-110)"
say "the key may read other files? $(ssh -n privrepo 'cat /etc/passwd' 2>&1 | head -n 1 | cut -c1-110)"
say "evaluate the host from that source (dry): $(nix eval --raw "$R#nixosConfigurations.lab.config.system.build.toplevel.drvPath" --refresh 2>&1 | grep -v '^evaluation warning' | tail -n 1 | sed 's#/nix/store/[a-z0-9]*-##' | cut -c1-80)"
say "-- the key is removed from the repository's access (the owner revokes the deploy key)"
: > /home/lab/.ssh/authorized_keys
say "fetch again: $(nix flake metadata $R --refresh 2>&1 | grep -E 'error|Permission|denied|Could not' | head -n 2 | tr '\n' ' ' | cut -c1-200)"
say "-- the server's host key changes (a machine pretending to be the repository)"
echo "[localhost]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" > /root/.ssh/kh
echo "restrict,command=\"$GITBIN/git-shell -c \\\"\$SSH_ORIGINAL_COMMAND\\\"\" $(cat /root/.ssh/dk.pub)" >> /home/lab/.ssh/authorized_keys
say "fetch with a wrong host key: $(nix flake metadata $R --refresh 2>&1 | grep -E 'verification failed|REMOTE HOST|error' | head -n 2 | tr '\n' ' ' | cut -c1-200)"
: > /home/lab/.ssh/authorized_keys
say "== (b) --override-input instead of --update-input: the module changes in the PUBLIC repository (the host deploys it by itself with the old flags), then the private values set tidepool.deploy.inputs"
cd /root/pubwork; cp /home/lab/nixos/modules/deploy.nix modules/deploy.nix; $G add -A; $G commit -qm "deploy module: inputs"; $G push -q origin main; mt=$(ms)
for i in $(seq 1 240); do cat $(systemctl cat nixos-upgrade.service 2>/dev/null | grep -oE '/nix/store/[^ ]*nixos-upgrade-start') 2>/dev/null | grep -q -- '--update-input' || break; sleep 2; done
say "the host deployed the new module after $(( ($(ms) - mt) / 1000 )) s; its command now has no --update-input: $(cat $(systemctl cat nixos-upgrade.service | grep -oE '/nix/store/[^ ]*nixos-upgrade-start') | grep -c -- '--update-input' | sed 's/^0$/yes/')"
cd /root/privwork; cat > host.nix <<'N'
{ ... }: { tidepool.deploy = { enable = true; flake = "git+file:///srv/git/priv.git#lab"; interval = "minutely"; inputs.tidepool = "git+file:///srv/git/pub.git"; }; }
N
nix flake update tidepool 2>&1 | grep -E "^error" | head -n 2; $G add -A; $G commit -qm "override-input"; $G push -q origin main; mt=$(ms)
for i in $(seq 1 240); do cat $(systemctl cat nixos-upgrade.service 2>/dev/null | grep -oE '/nix/store/[^ ]*nixos-upgrade-start') 2>/dev/null | grep -q -- '--override-input' && break; sleep 2; done
say "the private values reached the host after $(( ($(ms) - mt) / 1000 )) s; the command: $(cat $(systemctl cat nixos-upgrade.service | grep -oE '/nix/store/[^ ]*nixos-upgrade-start') | grep -oE '\-\-override-input [^ ]+ [^ ]+' | head -n 1 | cut -c1-120)"
cd /root/pubwork; printf '{ ... }: { environment.etc."tidepool-marker".text = "%s"; }\n' b1 > modules/marker.nix; $G add -A; $G commit -qm b1; $G push -q origin main; mt=$(ms)
for i in $(seq 1 300); do [ "$(marker)" = b1 ] && break; sleep 1; done
say "a merge in the public repository: marker $(marker) after $(( ($(ms) - mt) / 1000 )) s"
sleep 100; say "deprecation warnings in the last ticks: $(journalctl -u nixos-upgrade --no-pager -o cat --since '-2min' | grep -ciE 'deprecated alias')"
say done
