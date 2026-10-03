#!/usr/bin/env bash
# =============================================================================
# lab/updates-u12.sh — phase 8 follow-up (ADR 0016), U12: two things the owner asked for, built into the integrated flake as switchable modules and tried in the lab:
#   a. push notifications with ntfy next to the mail (modules/push.nix, tidepool.push.enable)       b. the local NAS on the 2 TB disk (modules/nas.nix, tidepool.nas.enable)
# Runs INSIDE the lab host as root; /home/lab/nixos is the flake with both modules and the extra secrets (ntfy-env, ntfy-bridge-env).
# =============================================================================
set -uo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH
export NIX_CONFIG='experimental-features = nix-command flakes
download-attempts = 60'
ms() { echo $(( $(date +%s%N) / 1000000 )); }
say() { echo "$(date +%H:%M:%S) $*"; }
say "== deploy: nixos-rebuild test with push.enable and nas.enable"
s=$(ms); nixos-rebuild test --flake path:/home/lab/nixos#lab 2>&1 | grep -v "^evaluation warning" | grep -E "error|Done|warning: the following|failed" | head -n 5 | cut -c1-200; say "done in $(( ($(ms) - s) / 1000 )) s; failed units: $(systemctl --failed --no-legend | tr -s ' ' | cut -d' ' -f2 | tr '\n' ' ')"
sleep 15
say "== a. ntfy"
say "services: ntfy-sh $(systemctl is-active ntfy-sh), alertmanager-ntfy $(systemctl is-active alertmanager-ntfy); memory: $(systemctl show ntfy-sh -p MemoryCurrent --value | awk '{printf "%d", $1/1048576}') MiB + $(systemctl show alertmanager-ntfy -p MemoryCurrent --value | awk '{printf "%d", $1/1048576}') MiB"
N="curl -sk -m 8 --resolve ntfy.lab.test:443:10.100.0.1"
say "without a login: HTTP $($N -o /dev/null -w %{http_code} https://ntfy.lab.test/alerts/json?poll=1)  (the topic is closed)"
say "with the login: HTTP $($N -u alerts:labpass -o /dev/null -w %{http_code} https://ntfy.lab.test/alerts/json?poll=1)"
say "through the VPN address only: the same name on the LAN address answers: $(curl -sk -m 4 --resolve ntfy.lab.test:443:10.0.2.15 -o /dev/null -w %{http_code} https://ntfy.lab.test/ 2>&1 | head -c 12)  (000 = refused)"
rm -f /tmp/lab-mail.log
t0=$(ms)
curl -s -XPOST localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[{"labels":{"alertname":"LabPushTest","severity":"critical","instance":"lab"},"annotations":{"summary":"push test"}}]' >/dev/null
for i in $(seq 1 40); do n=$($N -u alerts:labpass "https://ntfy.lab.test/alerts/json?poll=1&since=all" | grep -c LabPushTest); m=$(grep -c LabPushTest /tmp/lab-mail.log 2>/dev/null || echo 0); [ "$n" -gt 0 ] && [ "$m" -gt 0 ] && break; sleep 2; done
say "a critical alert posted to Alertmanager: push seen on the topic: $n, mail seen in the sink: $m, after $(( ($(ms) - t0) / 1000 )) s"
$N -u alerts:labpass "https://ntfy.lab.test/alerts/json?poll=1&since=all" | grep LabPushTest | head -n 1 | jq -r '"title: \(.title // "-") | message: \(.message[0:90])"' 2>/dev/null
journalctl -u alertmanager-ntfy --no-pager -o cat --since "-2min" | grep -iE "error|401|403|unauthor" | head -n 3 | cut -c1-200
say "== b. the NAS"
say "samba: smbd $(systemctl is-active samba-smbd), avahi $(systemctl is-active avahi-daemon); memory: $(systemctl show samba-smbd -p MemoryCurrent --value | awk '{printf "%d", $1/1048576}') MiB"
printf 'labnaspw\nlabnaspw\n' | smbpasswd -a -s nas >/dev/null 2>&1; say "the share user's password has to be set with smbpasswd (the module has no declarative way): $(pdbedit -L 2>/dev/null | head -n 1)"
echo "a file for the NAS" > /tmp/nasfile.txt
smbclient //127.0.0.1/NAS -U nas%labnaspw -c 'put /tmp/nasfile.txt hello.txt; mkdir folder; ls' 2>&1 | grep -E "hello|folder|NT_STATUS" | head -n 4
say "the file is on the 2 TB disk's folder: $(ls /mnt/big2tb/nas 2>&1 | tr '\n' ' '); owner: $(stat -c %U /mnt/big2tb/nas/hello.txt 2>/dev/null)"
say "a wrong password: $(smbclient //127.0.0.1/NAS -U nas%wrong -c ls 2>&1 | grep -o 'NT_STATUS[A-Z_]*' | head -n 1)"
say "no guest access: $(smbclient //127.0.0.1/NAS -N -c ls 2>&1 | grep -o 'NT_STATUS[A-Z_]*' | head -n 1)"
say "firewall: port 445 is open on $(nft list ruleset 2>/dev/null | grep -B2 -A2 'dport 445' | grep -oE 'iifname "[a-z0-9]+"' | sort -u | tr '\n' ' ') only"
say "avahi publishes: $(avahi-browse -a -t -r 2>/dev/null | grep -c smb) smb record(s)"
rm -f /mnt/big2tb/nas/hello.txt; rmdir /mnt/big2tb/nas/folder 2>/dev/null
say done
