#!/usr/bin/env bash
# =============================================================================
# lab/experiments/deploy-u22-encrypted.sh — ADR 0018 with ADR 0005: the server pulls a merged kernel change, the backups run, the new boot image is installed and signed, the reboot waits for its window,
# and the machine reboots BY ITSELF and opens its encrypted disks with the TPM. Runs on the WORKSTATION against host-s (UEFI, TPM, installed by lab/experiments/tpm-u21.sh or the DRILL_SECURE drill:
# Secure Boot on, all volumes sealed to PCR 7). Two local bare repositories stand in for the public and the private ones, as in lab/experiments/deploy-u16.sh.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; LAB="${TIDEPOOL_LAB:-$HOME/lab/tidepool}"; VM="$HERE/vm.sh"; D="$LAB/vms/host-s"
say() { echo "$(date +%H:%M:%S) $*"; }
S() { "$VM" ssh host-s "$@"; }
(cd "$HERE/../nixos" && tar cf - .) | S 'rm -rf ~/nixos; mkdir ~/nixos && cd ~/nixos && tar xf -'
cat > /tmp/u22-guest.sh <<'G'
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH NIX_CONFIG="experimental-features = nix-command flakes
download-attempts = 60"
cd /root 2>/dev/null || cd /
GITBIN=$(nix build --no-link --print-out-paths path:/home/lab/nixos#nixosConfigurations.lab-secure.pkgs.git | head -n 1)/bin; export PATH=$GITBIN:$PATH
say() { echo "$(date +%H:%M:%S) $*"; }
G="git -c user.email=lab@lab.test -c user.name=lab"
rm -rf /srv/git /root/pubwork /root/privwork /root/.cache/nix; mkdir -p /srv/git
git init -q --bare -b main /srv/git/pub.git; git init -q --bare -b main /srv/git/priv.git
cp -r /home/lab/nixos /root/pubwork; cd /root/pubwork; rm -rf .git; git init -q -b main
printf '{ ... }: { environment.etc."tidepool-marker".text = "m0"; }\n' > modules/marker.nix; sed -i 's|    ./deploy.nix|    ./deploy.nix\n    ./marker.nix|' modules/default.nix
$G add -A; $G commit -qm init; git remote add origin /srv/git/pub.git; git push -q origin main
lo=$(date -d '+14 min' +%H:%M); up=$(date -d '+40 min' +%H:%M)
mkdir /root/privwork; cd /root/privwork; git init -q -b main
cat > flake.nix <<N
{
  inputs.tidepool.url = "git+file:///srv/git/pub.git";
  outputs = { self, tidepool, ... }: {
    nixosConfigurations.lab = tidepool.lib.mkHost ({ ... }: { imports = [ "\${tidepool}/hosts/lab-secure" ./host.nix ]; });
  };
}
N
cat > host.nix <<N
{ ... }: {
  tidepool.encryption.secureBoot = true;
  tidepool.deploy = { enable = true; flake = "git+file:///srv/git/priv.git#lab"; interval = "minutely"; inputs.tidepool = "git+file:///srv/git/pub.git";
                      reboot = { allow = true; window = { lower = "$lo"; upper = "$up"; }; }; };
}
N
$G add -A; nix flake lock 2>&1 | grep -E "^error" | head -2; $G add -A; $G commit -qm "private values"; git remote add origin /srv/git/priv.git; git push -q origin main
s=$(date +%s); nixos-rebuild switch --flake git+file:///srv/git/priv.git#lab 2>&1 | grep -v "^evaluation warning" | tail -n 2 | cut -c1-140; say "bootstrap from the private flake: $(( $(date +%s) - s )) s; window $lo to $up; now $(date +%H:%M); kernel $(uname -r); Secure Boot $(bootctl status 2>/dev/null | grep -m1 'Secure Boot' | tr -s ' ')"
say "the active script's window: $(grep -E '^(lower|upper)=' $(systemctl cat nixos-upgrade.service | grep -oE '/nix/store/[^ ]*nixos-upgrade-start' | head -1) | tr '\n' ' ')"
BA=$(BORG_PASSCOMMAND='cat /run/secrets/borg-passphrase' BORG_RELOCATED_REPO_ACCESS_IS_OK=yes borg list --short /mnt/backup16/borg-everything | wc -l)
say "== a kernel change is merged (6.12): the server installs and signs the boot image, the backups run first, and the reboot waits for the window"
cd /root/pubwork && printf '{ pkgs, ... }: { boot.kernelPackages = pkgs.linuxPackages_6_12; }\n' > modules/kernel.nix && sed -i 's|    ./marker.nix|    ./marker.nix\n    ./kernel.nix|' modules/default.nix && $G add -A && $G commit -qm "kernel 6.12" -q && $G push -q origin main
for i in $(seq 1 150); do journalctl -u nixos-upgrade --no-pager -o cat --since '-3min' | grep -q 'Outside of configured reboot window' && break; sleep 5; done
say "installed, outside the window: running $(uname -r); boot default's kernel $(readlink -f /nix/var/nix/profiles/system/kernel | cut -d/ -f4 | cut -c34-60); backups before it: Borg archives $BA -> $(BORG_PASSCOMMAND='cat /run/secrets/borg-passphrase' BORG_RELOCATED_REPO_ACCESS_IS_OK=yes borg list --short /mnt/backup16/borg-everything | wc -l)"
say "the new boot image is signed: $(sbctl verify 2>&1 | grep -E 'Linux/nixos-generation' | tail -n 1 | cut -c1-100)"
cd /root/pubwork && printf '{ ... }: { environment.etc."tidepool-marker".text = "m1"; }\n' > modules/marker.nix && $G add -A && $G commit -qm "marker m1" -q && $G push -q origin main
sleep 150
say "a second merge while the reboot is pending is held too: the marker is $(cat /etc/tidepool-marker)"
say "PCR 7 before the reboot: $(systemd-analyze pcrs 7 | tail -n 1 | tr -s ' ' | cut -c1-44); waiting for the window ($lo to $up); now $(date +%H:%M)"
G
cat /tmp/u22-guest.sh | S 'cat > /tmp/u22-guest.sh'
S 'sudo -E env PATH=$PATH bash /tmp/u22-guest.sh < /dev/null' 2>&1 | grep -v "^warning: \$HOME"
say "== now the host waits: the reboot must happen inside the window and the disks must open by themselves"
down=0; L=$(wc -c < "$D/serial.log"); T0=$(date +%s)
for i in $(seq 1 600); do if S true >/dev/null 2>&1; then if [ $down -eq 1 ]; then say "the machine is back $(( $(date +%s) - D0 )) s after it went away"; break; fi; else if [ $down -eq 0 ]; then down=1; D0=$(date +%s); say "the machine went away (the reboot in the window) at $(date +%H:%M:%S)"; fi; fi; sleep 3; done
sleep 25
say "passphrase prompts during that reboot: $(tail -c +$((L+1)) "$D/serial.log" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -c 'Please enter passphrase')"
say "kernel $(S uname -r); marker $(S 'cat /etc/tidepool-marker') (m1 = the held merge, live after the reboot); Secure Boot: $(S 'sudo bootctl status 2>/dev/null | grep -m1 "Secure Boot" | tr -s " "'); PCR 7: $(S 'sudo systemd-analyze pcrs 7 | tail -n 1 | tr -s " " | cut -c1-44')"
say "volumes: $(S 'findmnt -rn / /mnt/big2tb /srv/data -o TARGET,SOURCE | tr -s " " | tr "\n" ";"'); failed units: $(S 'systemctl --failed --no-legend | wc -l'); services: immich $(S 'curl -s -m 10 -o /dev/null -w %{http_code} 127.0.0.1:2283/api/server/ping'), vaultwarden $(S 'curl -s -m 10 -o /dev/null -w %{http_code} 127.0.0.1:8222/alive')"
