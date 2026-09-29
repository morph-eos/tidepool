#!/usr/bin/env bash
# =============================================================================
# SETUP KDUMP — enables kernel crash dump collection
# =============================================================================
# What kdump does:
# - Reserves a portion of RAM at boot for a second kernel ("crash kernel")
# - On a kernel panic / fatal oops / hard hang with NMI, the main
#   kernel jumps to the crash kernel, which dumps the first kernel's memory
#   to /var/crash/<timestamp>/ (vmcore + dmesg)
# - It then lets you analyze the dump with `crash` or `gdb` to find the
#   driver/function that caused the panic
#
# When it is NOT useful:
# - Electrical hard reset (the kernel is no longer running)
# - Network loss without a panic (see the 30 Apr 2026 case: kernel alive, WiFi down)
# - Application crash (systemd-coredump exists for that)
#
# When it is useful:
# - Kernel panic (buggy driver, BUG_ON, NULL deref)
# - Soft/hard lockup (stuck CPU) → triggers a panic via the watchdog
# - Machine Check Exception (MCE: ECC RAM, CPU bug)
#
# Cost: ~256 MB of RAM reserved at boot.
# Space: each dump ~ the size of the RAM in use (compressed with makedumpfile, usually
# 200-800 MB). Old dumps must be pruned by hand or via cron.
# =============================================================================
set -euo pipefail

[[ $EUID -ne 0 ]] && exec sudo "$0" "$@"

CRASHKERNEL="${CRASHKERNEL:-256M-:256M}"   # ≥256MB RAM → reserve 256MB
KEEP_DUMPS="${KEEP_DUMPS:-3}"               # keep the last N dumps

log() { echo "[kdump-setup] $*"; }

log "1/5 Installazione pacchetti (linux-crashdump, makedumpfile, kdump-tools, crash)"
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    linux-crashdump kdump-tools makedumpfile crash kexec-tools >/dev/null

log "2/5 Configurazione /etc/default/kdump-tools"
KDUMP_CFG=/etc/default/kdump-tools
if [[ -f "$KDUMP_CFG" ]]; then
    sed -i 's/^USE_KDUMP=.*/USE_KDUMP=1/' "$KDUMP_CFG"
    grep -q '^USE_KDUMP=' "$KDUMP_CFG" || echo 'USE_KDUMP=1' >> "$KDUMP_CFG"
    # compress dumps (-c -d 31), skip zero/cache/free pages
    sed -i 's|^MAKEDUMP_ARGS=.*|MAKEDUMP_ARGS="-c -d 31"|' "$KDUMP_CFG"
    grep -q '^MAKEDUMP_ARGS=' "$KDUMP_CFG" || echo 'MAKEDUMP_ARGS="-c -d 31"' >> "$KDUMP_CFG"
    # keep the last N dumps
    sed -i "s|^NUM_DUMPS=.*|NUM_DUMPS=$KEEP_DUMPS|" "$KDUMP_CFG"
    grep -q '^NUM_DUMPS=' "$KDUMP_CFG" || echo "NUM_DUMPS=$KEEP_DUMPS" >> "$KDUMP_CFG"
fi

log "3/5 Configurazione GRUB: crashkernel=$CRASHKERNEL + sysrq + watchdog panic"
GRUB=/etc/default/grub
cp -a "$GRUB" "${GRUB}.bak.$(date +%Y%m%d-%H%M%S)"

# Extract the current line, remove the parameters we reconfigure, add the new ones
CURRENT=$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB" | sed -E 's/^[^"]*"(.*)"$/\1/')
CLEANED=$(echo "$CURRENT" | sed -E '
    s/\bcrashkernel=[^ ]*//g;
    s/\bsysrq_always_enabled=[^ ]*//g;
    s/\bsoftlockup_panic=[^ ]*//g;
    s/\bhardlockup_panic=[^ ]*//g;
    s/\bnmi_watchdog=[^ ]*//g;
    s/\bpanic=[^ ]*//g;
    s/  +/ /g;
    s/^ +| +$//g
')
NEW="${CLEANED} crashkernel=${CRASHKERNEL} sysrq_always_enabled=1 softlockup_panic=1 nmi_watchdog=1 panic=10"
NEW=$(echo "$NEW" | sed 's/  */ /g; s/^ //; s/ $//')

if grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB"; then
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${NEW}\"|" "$GRUB"
else
    echo "GRUB_CMDLINE_LINUX_DEFAULT=\"${NEW}\"" >> "$GRUB"
fi
log "Cmdline kernel (next boot): $NEW"

log "4/5 update-grub + abilitazione kdump-tools"
update-grub 2>&1 | tail -3
systemctl enable kdump-tools.service >/dev/null

log "5/5 Stato attuale (kdump si attiva al PROSSIMO boot, serve reservation crashkernel)"
echo "  - kexec-tools:   $(dpkg -l kexec-tools 2>/dev/null | awk '/^ii/{print $3}')"
echo "  - kdump-tools:   $(systemctl is-enabled kdump-tools.service 2>&1)"
echo "  - crashkernel:   $(grep -oE 'crashkernel=[^ ]+' /proc/cmdline 2>/dev/null || echo 'NON ATTIVO (riavvia)')"
echo "  - vmcore dir:    /var/crash/"
echo
echo "Per attivare ora serve un REBOOT. Dopo il riavvio verifica con:"
echo "    kdump-config show"
echo "    cat /sys/kernel/kexec_crash_loaded   # deve essere 1"
echo
echo "Test (DISTRUTTIVO, causa kernel panic immediato):"
echo "    echo c | sudo tee /proc/sysrq-trigger"
echo
log "Fatto. Backup GRUB: ${GRUB}.bak.*"
