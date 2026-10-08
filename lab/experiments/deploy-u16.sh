#!/usr/bin/env bash
# =============================================================================
# lab/experiments/deploy-u16.sh — ADR 0018: the server pulls and applies what was merged (system.autoUpgrade), the backups run BEFORE the change is activated (system.preSwitchChecks),
# a private flake imports the public one. Two local bare repositories stand in for the public and the private GitHub repositories.
# Runs INSIDE the lab host as root; /home/lab/nixos is the flake with modules/deploy.nix.
# =============================================================================
set -uo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH
export NIX_CONFIG='experimental-features = nix-command flakes
download-attempts = 60'
GITBIN=$(nix build --no-link --print-out-paths path:/home/lab/nixos#nixosConfigurations.lab.pkgs.git | head -n 1)/bin; export PATH=$GITBIN:$PATH   # git is installed by modules/deploy.nix once it is enabled: the first build needs it already
ms() { echo $(( $(date +%s%N) / 1000000 )); }
say() { echo "$(date +%H:%M:%S) $*"; }
G="git -c user.email=lab@lab.test -c user.name=lab"
marker() { cat /etc/tidepool-marker 2>/dev/null || echo none; }
wait_marker() { local want=$1 max=${2:-300}; for i in $(seq 1 $max); do [ "$(marker)" = "$want" ] && return 0; sleep 1; done; return 1; }
push_marker() { cd /root/pubwork && printf '{ ... }: { environment.etc."tidepool-marker".text = "%s"; }\n' "$1" > modules/marker.nix && $G add -A && $G commit -qm "marker $1" && $G push -q origin main; }
say "== setup: a 'public' and a 'private' repository (bare, local), and the lab host built from the PRIVATE flake once, by hand"
rm -rf /srv/git /root/pubwork /root/privwork /root/.cache/nix; mkdir -p /srv/git
git init -q --bare -b main /srv/git/pub.git; git init -q --bare -b main /srv/git/priv.git
cp -r /home/lab/nixos /root/pubwork; cd /root/pubwork; rm -rf .git; git init -q -b main
printf '{ ... }: { environment.etc."tidepool-marker".text = "v1"; }\n' > modules/marker.nix; sed -i 's|    ./deploy.nix|    ./deploy.nix\n    ./marker.nix|' modules/default.nix
$G add -A; $G commit -qm init; git remote add origin /srv/git/pub.git; git push -q origin main
mkdir /root/privwork; cd /root/privwork; git init -q -b main
cat > flake.nix <<'N'
{
  inputs.tidepool.url = "git+file:///srv/git/pub.git";
  outputs = { self, tidepool, ... }: {
    nixosConfigurations.lab = tidepool.lib.mkHost ({ ... }: { imports = [ "${tidepool}/hosts/lab" ./host.nix ]; });
  };
}
N
cat > host.nix <<'N'
# the private values: here only the deploy settings
{ ... }: { tidepool.deploy = { enable = true; flake = "git+file:///srv/git/priv.git#lab"; interval = "minutely"; }; }
N
$G add -A; nix flake lock 2>&1 | grep -E "error" | head -n 2; $G add -A; $G commit -qm "private values"; git remote add origin /srv/git/priv.git; git push -q origin main
s=$(ms); nixos-rebuild switch --flake git+file:///srv/git/priv.git#lab 2>&1 | grep -v "^evaluation warning" | grep -E "error|Done|warning: the following" | head -n 3 | cut -c1-200
say "bootstrap from the private flake: $(( ($(ms) - s) / 1000 )) s; marker: $(marker); the timer: $(systemctl list-timers nixos-upgrade.timer --no-legend | tr -s ' ' | cut -d' ' -f1-4 | head -1); autoUpgrade command: $(systemctl cat nixos-upgrade.service | grep -oE 'nixos-rebuild[^ ]* switch .*' | head -1 | cut -c1-220)"
say "== A. idle ticks: the timer runs every minute and nothing has changed"
G0=$(readlink /run/current-system); sleep 200
say "ticks seen: $(journalctl -u nixos-upgrade --no-pager -o cat --since '-4min' | grep -c 'Finished\|Deactivated successfully')"
journalctl -u nixos-upgrade --no-pager -o cat --since '-4min' | grep -E "Consumed" | tail -n 3 | sed 's/.*Consumed/  consumed/' | cut -c1-120
say "the system generation did not change: $([ "$(readlink /run/current-system)" = "$G0" ] && echo yes || echo NO); backups started by the idle ticks: $(journalctl -u nixos-upgrade --no-pager -o cat --since '-4min' | grep -c 'pre-switch backup')"
journalctl -u nixos-upgrade --no-pager -o cat --since '-4min' | grep -iE "deprecat|warning:" | sort -u | head -n 3 | cut -c1-180
say "== B. a merge in the PUBLIC repository is a deploy: marker v1 -> v2"
mt=$(ms); push_marker v2; date +%H:%M:%S | sed 's/^/  pushed at /'
wait_marker v2 400 && say "marker v2 live after $(( ($(ms) - mt) / 1000 )) s" || say "marker NOT updated"
journalctl -u nixos-upgrade --no-pager -o short-precise --since "-8min" | grep -E "pre-switch backup|activating the configuration|FAILED|switching to system|Started|Finished" | sed -E 's/ tidepool-lab [^:]*:/ /' | cut -c1-150 | tail -n 12
say "  Borg archives (newest 3): $(BORG_PASSCOMMAND='cat /run/secrets/borg-passphrase' BORG_RELOCATED_REPO_ACCESS_IS_OK=yes borg list --last 3 --short /mnt/backup16/borg-everything 2>&1 | tr '\n' ' ')"
say "  pgBackRest: $(sudo -u postgres pgbackrest info 2>&1 | grep -E 'full backup:|diff backup:' | tr -s ' ' | tr '\n' ' ')"
say "== C. a backup that fails: the Borg repository of everything disappears (unmounting the disk would not do: systemd mounts it again), a merge arrives (v3) -> the change must NOT be activated"
mv /mnt/backup16/borg-everything /mnt/backup16/borg-everything.off; mt=$(ms); push_marker v3
sleep 150
say "marker after 150 s: $(marker) (v2 = held back); nixos-upgrade: $(systemctl show nixos-upgrade -p Result --value) / $(systemctl is-failed nixos-upgrade)"
journalctl -u nixos-upgrade --no-pager -o cat --since "-4min" | grep -E "pre-switch backup" | sort -u | head -n 4 | cut -c1-170
say "waiting for the UnitFailed mail (rule: failed for 5 minutes)"; rm -f /tmp/lab-mail.log 2>/dev/null; for i in $(seq 1 60); do grep -q "UnitFailed" /tmp/lab-mail.log 2>/dev/null && break; sleep 10; done
say "mail: $(grep -h UnitFailed /tmp/lab-mail.log 2>/dev/null | head -n 1 | cut -c1-120) (after $(( ($(ms) - mt) / 1000 )) s since the merge)"
mv /mnt/backup16/borg-everything.off /mnt/backup16/borg-everything; mt=$(ms)
wait_marker v3 300 && say "repository back: the next tick applied v3 after $(( ($(ms) - mt) / 1000 )) s" || say "v3 NOT applied after the repository came back"
say "== D. a broken commit (does not evaluate), then the fix"
cd /root/pubwork; printf '{ ... }: { environment.etc."tidepool-marker".text = "v4" ; this is not nix\n' > modules/marker.nix; $G add -A; $G commit -qm broken; $G push -q origin main
sleep 130
say "marker: $(marker) (v3 = unchanged); the running generation unchanged: $([ "$(readlink /run/current-system)" = "$(readlink /nix/var/nix/profiles/system | sed 's#^#/nix/var/nix/profiles/#')" ] && echo yes || echo see-below); nixos-upgrade: $(systemctl is-failed nixos-upgrade)"
journalctl -u nixos-upgrade --no-pager -o cat --since "-3min" | grep -E "error:" | head -n 2 | cut -c1-170
push_marker v5; mt=$(ms); wait_marker v5 300 && say "the fix (v5) applied after $(( ($(ms) - mt) / 1000 )) s; nixos-upgrade: $(systemctl is-failed nixos-upgrade)"
say done
