#!/usr/bin/env bash
# =============================================================================
# lab/experiments/nas-u14.sh — ADR 0017: the local NAS built into the flake (modules/nas.nix) with a Time Machine share, its Samba user, and its place in the Borg job of everything.
# Runs INSIDE the lab host as root; /home/lab/nixos is the flake (tidepool.nas.enable, a lanInterface, a Time Machine path).
# =============================================================================
set -uo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH
export NIX_CONFIG='experimental-features = nix-command flakes
download-attempts = 60'
say() { echo "$(date +%H:%M:%S) $*"; }
say "== deploy"; nixos-rebuild test --flake path:/home/lab/nixos#lab 2>&1 | grep -E "error|Done" | head -n 3 | cut -c1-160; sleep 8
say "failed units: $(systemctl --failed --no-legend | tr -s ' ' | cut -d' ' -f2 | tr '\n' ' ')"
say "samba $(systemctl is-active samba-smbd), avahi $(systemctl is-active avahi-daemon); memory: $(systemctl show samba-smbd -p MemoryCurrent --value | awk '{printf "%d", $1/1048576}') MiB"
say "== the Samba user: before any step, the password database has: $(pdbedit -L 2>/dev/null | wc -l) user(s); the one manual step:"
printf 'labnaspw\nlabnaspw\n' | smbpasswd -a -s nas >/dev/null 2>&1; say "  smbpasswd -a nas -> $(pdbedit -L | head -n 1)"
say "  where the database lives: $(ls /var/lib/samba/private/passdb.tdb 2>&1)"
echo "a file for the NAS" > /tmp/nasfile.txt
smbclient //127.0.0.1/NAS -U nas%labnaspw -c 'put /tmp/nasfile.txt hello.txt; mkdir folder; ls' 2>&1 | grep -E "hello|folder|NT_STATUS" | head -n 3
smbclient //127.0.0.1/TimeMachine -U nas%labnaspw -c 'put /tmp/nasfile.txt tm.txt; ls' 2>&1 | grep -E "tm.txt|NT_STATUS" | head -n 2
say "wrong password: $(smbclient //127.0.0.1/NAS -U nas%wrong -c ls 2>&1 | grep -o 'NT_STATUS[A-Z_]*' | head -n 1); no guest: $(smbclient //127.0.0.1/NAS -N -c ls 2>&1 | grep -o 'NT_STATUS[A-Z_]*' | head -n 1)"
say "share list as the Mac sees it: $(smbclient -L 127.0.0.1 -U nas%labnaspw 2>&1 | grep -E 'Disk' | tr -s ' ' | cut -d' ' -f2 | tr '\n' ' ')"
say "time machine settings: $(testparm -s --parameter-name='fruit:time machine' --section-name=TimeMachine 2>/dev/null | head -n1)"
say "firewall: 445 open on $(nft list ruleset | grep -B3 'dport 445' | grep -oE 'iifname "[a-z0-9]+"' | sort -u | tr '\n' ' ') only; 5353 on $(nft list ruleset | grep -B3 'dport 5353' | grep -oE 'iifname "[a-z0-9]+"' | sort -u | tr '\n' ' ') only"
say "avahi records: smb $(avahi-browse -a -t -r 2>/dev/null | grep -c '_smb._tcp'), adisk $(avahi-browse -a -t -r 2>/dev/null | grep -c '_adisk._tcp')"
say "== the share is in the Borg job of everything"
say "paths of the job: $(systemctl cat borgbackup-job-everything | grep -oE '/mnt/big2tb/nas|/var/lib/samba' | sort -u | tr '\n' ' ')"
systemctl start borgbackup-job-everything 2>/dev/null; for i in $(seq 1 90); do systemctl is-active -q borgbackup-job-everything || break; sleep 2; done
say "job result: $(systemctl show borgbackup-job-everything -p Result --value)"
R=/mnt/backup16/borg-everything; export BORG_PASSCOMMAND="cat /run/secrets/borg-passphrase" BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
A=$(borg list --last 1 --short $R 2>&1 | tail -n 1); say "last archive: $A"
say "the NAS file in it: $(borg list $R::$A 2>/dev/null | grep -c 'big2tb/nas/hello.txt'); the Samba users' database in it: $(borg list $R::$A 2>/dev/null | grep -c 'var/lib/samba/private/passdb.tdb'); the Time Machine share (must NOT be): $(borg list $R::$A 2>/dev/null | grep -c 'timemachine/tm.txt')"
rm -rf /mnt/big2tb/nas/hello.txt /mnt/big2tb/nas/folder /mnt/big2tb/timemachine/tm.txt
say done
