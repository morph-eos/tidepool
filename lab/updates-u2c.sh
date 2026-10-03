#!/usr/bin/env bash
# =============================================================================
# lab/updates-u2c.sh — phase 8 (ADR 0016), U2c: an update that needs a REBOOT (a new kernel). Run from the WORKSTATION against the lab host-t after updates-u1.sh built /root/u1out/new-30.
# Sets the new system as the boot default (`switch-to-configuration boot`), reboots, and times, from the reboot command, when ssh answers and when every service answers.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; VM="$HERE/vm.sh"
H() { "$VM" ssh host-t "$@"; }
say() { echo "$(date +%H:%M:%S) $*"; }
chk='curl -sk -m 3 -o /dev/null -w %{http_code} --resolve vault.lab.test:443:127.0.0.1 https://vault.lab.test/alive | grep -qE "^(200|301|302)$" && curl -sk -m 3 -o /dev/null -w %{http_code} --resolve cloud.lab.test:443:127.0.0.1 https://cloud.lab.test/status.php | grep -qE "^(200|301|302)$" && curl -sf -m 3 http://127.0.0.1:2283/api/server/ping >/dev/null && pg_isready -q -h /run/postgresql && systemctl is-active --quiet pgbackrest-default-daily.timer borgbackup-job-everything.timer prometheus alertmanager'
say "before: kernel $(H 'uname -r'), booted system $(H 'readlink /run/booted-system | cut -c12-40')"
H 'sudo /root/u1out/new-30/bin/switch-to-configuration boot >/dev/null 2>&1; echo "boot default set to: $(readlink /nix/var/nix/profiles/system | head -c 40)"; ls /nix/var/nix/profiles | head -n 0'
say "the running kernel after the switch to boot (nothing changes until the reboot): $(H 'uname -r'); the new system's kernel: $(H 'readlink /root/u1out/new-30/kernel | sed "s#.*linux-##; s#/.*##"')"
t0=$(date +%s); H 'sudo systemctl reboot' >/dev/null 2>&1; sleep 5
ssh_t=""; all_t=""
for i in $(seq 1 120); do
  if [ -z "$ssh_t" ] && H true >/dev/null 2>&1; then ssh_t=$(( $(date +%s) - t0 )); say "ssh answers $ssh_t s after the reboot command"; fi
  if [ -n "$ssh_t" ] && H "$chk" >/dev/null 2>&1; then all_t=$(( $(date +%s) - t0 )); break; fi
  sleep 3
done
say "every service answers $all_t s after the reboot command (Vaultwarden, Nextcloud, Immich, PostgreSQL, the backup timers, Prometheus, Alertmanager)"
say "after: kernel $(H 'uname -r'), ZFS module $(H 'cat /sys/module/zfs/version 2>/dev/null'), userland $(H 'zfs version 2>/dev/null | head -n 1'), units failed: $(H 'systemctl --failed --no-legend | wc -l')"
say "pool: $(H 'zpool status -x 2>&1 | head -n 1')"
say done
