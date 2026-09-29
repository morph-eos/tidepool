#!/usr/bin/env bash
# =============================================================================
# lab/check-host.sh — verify a lab VM against docs/specs/host.md (H01-H09)
#
# Usage: lab/check-host.sh <vm-name> [--no-secret]
#
# It runs read-only checks inside the VM over SSH and prints one PASS/FAIL line
# per requirement. Exit status is the number of failed checks (0 = all green).
# It does not know which tool built the machine.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="${1:?usage: check-host.sh <vm-name> [--no-secret]}"
WITH_SECRET=1; [ "${2:-}" = "--no-secret" ] && WITH_SECRET=0

# The remote script is sent on stdin to "sudo bash -s"; it prints "PASS|FAIL id text".
REMOTE=$(cat <<'REMOTE_EOF'
r() { # r <id> <description> <command...>
    local id="$1" desc="$2"; shift 2
    if "$@" >/dev/null 2>&1; then echo "PASS $id $desc"; else echo "FAIL $id $desc"; fi
}
sshcfg=$(sshd -T 2>/dev/null)
# H01
r H01 "admin user with an SSH key and sudo" bash -c 'u=$(getent group sudo | cut -d: -f4 | cut -d, -f1); [ -n "$u" ] && [ -s "/home/$u/.ssh/authorized_keys" ]'
# H02
r H02a "sshd listens on 2222" bash -c 'ss -ltn | grep -qE ":2222\b"'
r H02b "sshd does not listen on 22" bash -c '! ss -ltn | grep -qE ":22\s"'
r H02c "password login off" bash -c 'echo "$0" | grep -qi "^passwordauthentication no"' "$sshcfg"
# sshd -T prints the canonical name: "prohibit-password" is reported as "without-password"
r H02d "root login prohibit-password" bash -c 'echo "$0" | grep -qiE "^permitrootlogin (prohibit-password|without-password)"' "$sshcfg"
r H02e "MaxAuthTries 3" bash -c 'echo "$0" | grep -qi "^maxauthtries 3"' "$sshcfg"
# H03
r H03a "fail2ban is active" systemctl is-active --quiet fail2ban
# -R follows symlinks: on some systems the configuration is a link into a read-only store
r H03b "sshd jail on 2222, maxretry 3" bash -c 'out=$(fail2ban-client get sshd maxretry 2>/dev/null; fail2ban-client status sshd 2>/dev/null); echo "$out" | grep -q "^3$" && grep -RqE "port\s*=\s*.?2222" /etc/fail2ban/'
# H04
r H04a "Docker Engine is installed and answers" bash -c '[ -n "$(docker version --format "{{.Server.Version}}" 2>/dev/null)" ]'
r H04b "Compose plugin present" docker compose version
r H04c "docker service enabled" systemctl is-enabled --quiet docker
# H05
r H05a "kernel cmdline has crashkernel=" grep -q "crashkernel=" /proc/cmdline
r H05b "kernel cmdline has softlockup_panic=1" grep -q "softlockup_panic=1" /proc/cmdline
# Functional: the crash kernel is loaded and holds exactly 256 MiB (a second crashkernel= on the command line silently wins)
r H05c "crash kernel loaded (kexec)" bash -c '[ "$(cat /sys/kernel/kexec_crash_loaded)" = 1 ]'
r H05d "crash kernel reserves 256 MiB" bash -c '[ "$(cat /sys/kernel/kexec_crash_size)" = 268435456 ]'
# H06
r H06 "tidepool-fixperms.timer enabled and active" bash -c 'systemctl is-enabled --quiet tidepool-fixperms.timer && systemctl is-active --quiet tidepool-fixperms.timer'
# H07
disk=/dev/disk/by-id/virtio-TPDATA0001
r H07a "data disk found by serial" test -b "$disk"
r H07b "ext4 filesystem on the data disk" bash -c '[ "$(blkid -o value -s TYPE "$(readlink -f '"$disk"')")" = ext4 ]'
r H07c "mounted on /mnt/nas" mountpoint -q /mnt/nas
r H07d "fstab uses a stable identifier for /mnt/nas" bash -c 'grep -E "^(UUID=|/dev/disk/by-)\S+\s+/mnt/nas\s" /etc/fstab'
# H08
r H08a "time zone Europe/Rome" bash -c '[ "$(timedatectl show -p Timezone --value)" = Europe/Rome ]'
# The first NTP sync after a boot takes a few seconds: wait up to 90 s before calling it a failure
r H08b "clock synchronized" bash -c 'for i in $(seq 1 45); do [ "$(timedatectl show -p NTPSynchronized --value)" = yes ] && exit 0; sleep 2; done; exit 1'
REMOTE_EOF
)
if [ "$WITH_SECRET" = 1 ]; then
REMOTE+=$'\n'$(cat <<'REMOTE_EOF'
# H09
r H09a "secrets.env is root:root 0600" bash -c '[ "$(stat -c "%U:%G %a" /etc/tidepool/secrets.env)" = "root:root 600" ]'
r H09b "secrets.env holds TIDEPOOL_TEST_SECRET" grep -q "^TIDEPOOL_TEST_SECRET=." /etc/tidepool/secrets.env
REMOTE_EOF
)
fi

out=$("$HERE/vm.sh" ssh "$NAME" 'sudo bash -s' <<<"$REMOTE") || { echo "cannot reach $NAME"; exit 255; }
fails=0; pass=0
while read -r status id text; do
    [ -n "$status" ] || continue
    if [ "$status" = PASS ]; then pass=$((pass + 1)); printf '  \033[32mPASS\033[0m %-5s %s\n' "$id" "$text"
    else fails=$((fails + 1)); printf '  \033[31mFAIL\033[0m %-5s %s\n' "$id" "$text"; fi
done <<<"$out"
echo "---"; echo "$pass passed, $fails failed"
# A checker that ran nothing must never look green
if [ $((pass + fails)) -eq 0 ]; then echo "no results received from $NAME: the checks did not run"; exit 254; fi
exit "$fails"
