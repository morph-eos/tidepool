#!/usr/bin/env bash
# =============================================================================
# lab/private-repo-u24.sh — the last test before the real deployment: the PRIVATE repository made from private-repo-template/ with test values, importing the REAL public layout
# (the repository with its flake in nixos/, read as git+file://...?dir=nixos, as github:OWNER/tidepool?dir=nixos will be), and building THE REAL HOST: the encrypted layout, the signed boot,
# the WiFi, the firmware, the deploy and Renovate modules, the NAS, push. Then the pin bump the way .github/workflows/bump-public.yml does it.
# Runs INSIDE the lab host as root. /tmp/pub.git.tar is a bare clone of the repository, /tmp/tplsrc/private-repo-template the template, /tmp/lab-secrets.yaml the lab secrets file.
# =============================================================================
set -uo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH
export NIX_CONFIG='experimental-features = nix-command flakes
download-attempts = 60'
say() { echo "$(date +%H:%M:%S) $*"; }
G="git -c user.email=lab@lab.test -c user.name=lab"
GITBIN=$(nix build --no-link --print-out-paths path:/home/lab/nixos#nixosConfigurations.lab.pkgs.git | head -n 1)/bin; export PATH=$GITBIN:$PATH
JQ=$(nix build --no-link --print-out-paths "path:/home/lab/nixos#nixosConfigurations.lab.pkgs.jq^bin" | head -n 1)/bin; export PATH=$JQ:$PATH
say "== the public repository (a bare clone of the real one) and the private one made from the template"
rm -rf /srv/git /root/priv /root/pubclone; mkdir -p /srv/git; tar -C /srv/git -xf /tmp/pub.git.tar
cp -r /tmp/tplsrc/private-repo-template /root/priv; cd /root/priv; rm -rf .git
sed -i 's|github:OWNER/tidepool?dir=nixos|git+file:///srv/git/pub.git?dir=nixos|' flake.nix
sed -i -e 's|REPLACE-system-ssd|test-system|; s|REPLACE-tank-ssd|test-tank|; s|REPLACE-16tb-part1|test-16tb|; s|REPLACE-2tb-part1|test-2tb|; s|REPLACE-with-your-network-name|Lab Net|; s|ssh-ed25519 AAAA... admin|'"$(cat /home/lab/nixos/keys/admin.pub)"'|' host.nix
cp /tmp/lab-secrets.yaml secrets.yaml
say "the template, filled with test values: $(grep -cE 'REPLACE|OWNER' host.nix) placeholders left (the deploy URL and Renovate's repository names stay: they are not read by the build)"
$G init -q -b main; $G add -A; nix flake lock 2>&1 | grep -E "^error|Added input 'tidepool'" | head -n 2; $G add -A; $G commit -qm "private values"
say "the lock pins the public repository at $(jq -r '.nodes.tidepool.locked.rev[0:8]' flake.lock) (dir=$(jq -r '.nodes.tidepool.locked.dir' flake.lock)); nixpkgs from the public lock: $(jq -r '.nodes.nixpkgs.locked.rev[0:8]' flake.lock)"
say "== the real host builds"
s=$(date +%s); nix build --no-link --print-out-paths .#nixosConfigurations.tidepool.config.system.build.toplevel > /tmp/top.path 2> /tmp/top.err; rc=$?; say "toplevel: exit $rc in $(( $(date +%s) - s )) s; $(tail -n 1 /tmp/top.err | cut -c1-120)"
[ $rc -eq 0 ] && T=$(tail -n 1 /tmp/top.path) && say "closure: $(nix path-info -S $T | awk '{printf "%.1f GiB", $2/1073741824}')"
s=$(date +%s); nix build --no-link --print-out-paths .#nixosConfigurations.tidepool.config.system.build.diskoScript > /tmp/disko.path 2>/tmp/disko.err; say "the disko script (what formats the disks): exit $? in $(( $(date +%s) - s )) s"
D=$(tail -n 1 /tmp/disko.path); say "it mentions: LUKS $(grep -c cryptsetup $D), zpool $(grep -c 'zpool create' $D), the 16 TB disk touched: $(grep -c 'test-16tb' $D)  (must be 0: backups are never formatted), the 2 TB disk touched: $(grep -c 'test-2tb' $D)  (must be 0)"
if [ $rc -eq 0 ]; then
  C() { nix eval --json ".#nixosConfigurations.tidepool.config.$1" 2>/dev/null | tail -n 1; }
  say "properties: secure boot (lanzaboote) $(C boot.lanzaboote.enable); initrd systemd $(C boot.initrd.systemd.enable); firmware $(C hardware.enableRedistributableFirmware); wifi $(C networking.wireless.enable); LAN interface $(C tidepool.lanInterface); deploy timer $(C system.autoUpgrade.dates); reboot allowed $(C system.autoUpgrade.allowReboot), window $(C system.autoUpgrade.rebootWindow); renovate $(C services.renovate.enable); borg sbctl path in the job: $(C services.borgbackup.jobs.everything.paths | grep -o sbctl | head -1)"
  say "kernel modules in the initrd: $(C boot.initrd.availableKernelModules | cut -c1-120)"
fi
say "== the pin bump, as .github/workflows/bump-public.yml does it: the public repository moves, the private one follows by a pull request"
cd /root; git clone -q /srv/git/pub.git pubclone; cd pubclone; git checkout -q reengineering 2>/dev/null || true
echo "a public change $(date +%s)" > docs/bump-test.md; $G add -A; $G commit -qm "docs: a public change"; git push -q origin HEAD:reengineering 2>&1 | tail -n 1
cd /root/priv; old=$(jq -r '.nodes.tidepool.locked.rev' flake.lock); nix flake update tidepool 2>&1 | grep -E "Updated|error" | head -n 2; new=$(jq -r '.nodes.tidepool.locked.rev' flake.lock)
say "old $old -> new $new: $([ "$old" != "$new" ] && echo 'the pin moved' || echo 'NOT moved')"
say "the same system after a docs-only public change (no deploy would follow): $(nix eval --raw .#nixosConfigurations.tidepool.config.system.build.toplevel.drvPath 2>/dev/null | tail -n 1 | sed 's#/nix/store/##' | cut -c1-40) vs before $(basename $T | cut -c1-40)"
say done
