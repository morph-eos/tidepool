#!/usr/bin/env bash
# =============================================================================
# lab/experiments/deploy-u20-window.sh — ADR 0018 section 9: with the reboot allowed and a time window, a deploy that changes the kernel is only INSTALLED (nixos-rebuild boot) until the window opens;
# a second merge meanwhile waits too. Runs INSIDE the lab host as root, after lab/experiments/deploy-u16.sh (the two local repositories) with the host built from the private flake whose
# `reboot.window` is later than now. The reboot itself is then watched from outside (ssh goes away, comes back).
# =============================================================================
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH NIX_CONFIG="experimental-features = nix-command flakes"
GITBIN=$(nix build --no-link --print-out-paths path:/home/lab/nixos#nixosConfigurations.lab.pkgs.git | head -n 1)/bin; export PATH=$GITBIN:$PATH
say() { echo "$(date +%H:%M:%S) $*"; }
G="git -c user.email=lab@lab.test -c user.name=lab"
S=$(systemctl cat nixos-upgrade.service | grep -oE "/nix/store/[^ ]*nixos-upgrade-start" | head -1); say "the active script's window: $(grep -E '^(lower|upper)=' $S | tr '\n' ' '); running kernel $(uname -r); marker $(cat /etc/tidepool-marker 2>/dev/null)"
cd /root/pubwork && printf '{ pkgs, ... }: { boot.kernelPackages = pkgs.linuxPackages_6_12; }\n' > modules/kernel.nix && printf '{ ... }: { environment.etc."tidepool-marker".text = "m0"; }\n' > modules/marker.nix && sed -i 's|    ./deploy.nix|    ./deploy.nix\n    ./kernel.nix\n    ./marker.nix|' modules/default.nix; grep -c "kernel.nix\|marker.nix" modules/default.nix; $G add -A && $G commit -qm "kernel 6.12 again" -q && $G push -q origin main
sleep 150
say "first deploy with a kernel change, OUTSIDE the window: running $(uname -r); boot default's kernel $(readlink -f /nix/var/nix/profiles/system/kernel | cut -d/ -f4 | cut -c34-60); active system's kernel $(readlink -f /run/current-system/kernel | cut -d/ -f4 | cut -c34-60)"
journalctl -u nixos-upgrade --no-pager -o cat --since '-2min' | grep -E "Outside of configured|Reboot scheduled|pre-switch backup" | sort | uniq -c | cut -c1-120
printf '{ ... }: { environment.etc."tidepool-marker".text = "m1"; }\n' > modules/marker.nix; $G add -A && $G commit -qm "marker m1" -q && $G push -q origin main
sleep 120
say "a SECOND merge (a marker) while the reboot is pending: the file says $(cat /etc/tidepool-marker) (m1 would mean it was activated); the boot default has it: $(grep -rl m1 $(readlink -f /nix/var/nix/profiles/system)/etc 2>/dev/null | wc -l) file(s)"
journalctl -u nixos-upgrade --no-pager -o cat --since '-2min' | grep -E "Outside of configured|pre-switch backup" | sort | uniq -c | cut -c1-120
say "waiting for the window (20:52-21:02); now $(date +%H:%M)"
