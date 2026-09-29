#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# SETUP CRON — configures cron jobs idempotently
# =============================================================================
# Each job is identified by a unique tag in the comment.
# The script adds/updates only the jobs with its own tag,
# without touching the other existing cron jobs.
#
# Usage:
#   sudo bash /mnt/nas2/nas-scripts/setup_cron.sh          # install/update
#   sudo bash /mnt/nas2/nas-scripts/setup_cron.sh remove    # remove only the managed jobs
#   sudo bash /mnt/nas2/nas-scripts/setup_cron.sh status    # show status
# =============================================================================

TAG="# [managed:nas-scripts]"
DOCKER_DIR="/mnt/nas2/docker"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[CRON]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Job definitions ---
# Format: LABEL|SCHEDULE|COMMAND|USER (root or user)
# SCHEDULE uses crontab syntax
JOBS=(
    # Weekly certbot restart (every 7 days, offset 3 so it does not collide with cleanup)
    "certbot-restart|0 5 */7 * *|cd ${DOCKER_DIR} && docker compose restart certbot 2>/dev/null|user"
    # Reload LE cert in Incus (symlink, a restart is enough — 30 min after certbot)
    "incus-cert-sync|30 5 */7 * *|systemctl restart incus|root"
    # Weekly log cleanup (different offset)
    "log-cleanup|0 4 */7 * *|/mnt/nas2/nas-scripts/cleanup_logs.sh|root"
    # Daily backup: offsite at 03:00 (dump+borg create, ~1min), then Proton
    # Drive mirror via user timer (03:30, see setup_proton_cli_backup.sh).
    # borg_backup_nas2.sh is DETACHED at 04:00 (no longer chained with ';'):
    # it scans all of /mnt/nas2 (heavier, duration not guaranteed <30min) and
    # overlapping with the Proton mirror (same /mnt/nas disk) caused I/O contention
    # -> ext4 soft lockup on 2026-07-04 (see the README, Lessons learned). REDACTED_DRIVE_TC runs
    # every night anyway, regardless of the outcome of backup_offsite.sh.
    "backup-offsite|0 3 * * *|sudo /mnt/nas2/nas-scripts/backup_offsite.sh|user"
    "backup-nas2-REDACTED_DRIVE|0 4 * * *|sudo /mnt/nas2/nas-scripts/borg_backup_nas2.sh|user"
)

# --- Functions ---

install_managed_job() {
    local label="$1" schedule="$2" command="$3" target_user="$4"
    local cron_line="${schedule} ${command} ${TAG} ${label}"

    local current_crontab
    if [ "$target_user" = "root" ]; then
        current_crontab=$(crontab -l 2>/dev/null || true)
    else
        current_crontab=$(crontab -u REDACTED_HOSTNAME -l 2>/dev/null || true)
    fi

    # Remove the old entry with the same label (if it exists)
    local filtered
    filtered=$(echo "$current_crontab" | grep -Fv "${TAG} ${label}" || true)

    # Also remove untagged entries that match the same command (migration)
    filtered=$(echo "$filtered" | grep -v "$(echo "$command" | sed 's/[.*+?^${}()|[\]/\\&/g')" || true)

    # Add the new entry
    local new_crontab
    if [ -n "$filtered" ]; then
        new_crontab="${filtered}"$'\n'"${cron_line}"
    else
        new_crontab="${cron_line}"
    fi

    # Remove excess blank lines and orphan comments
    new_crontab=$(echo "$new_crontab" | sed '/^$/d')

    if [ "$target_user" = "root" ]; then
        echo "$new_crontab" | crontab -
    else
        echo "$new_crontab" | crontab -u REDACTED_HOSTNAME -
    fi

    log "  [${target_user}] ${label}: ${schedule} ✓"
}

remove_managed_jobs() {
    for target_user in root REDACTED_HOSTNAME; do
        local current_crontab
        if [ "$target_user" = "root" ]; then
            current_crontab=$(crontab -l 2>/dev/null || true)
        else
            current_crontab=$(crontab -u "$target_user" -l 2>/dev/null || true)
        fi

        local filtered
        filtered=$(echo "$current_crontab" | grep -Fv "$TAG" || true)
        filtered=$(echo "$filtered" | sed '/^$/d')

        if [ -n "$filtered" ]; then
            if [ "$target_user" = "root" ]; then
                echo "$filtered" | crontab -
            else
                echo "$filtered" | crontab -u "$target_user" -
            fi
        else
            if [ "$target_user" = "root" ]; then
                crontab -r 2>/dev/null || true
            else
                crontab -u "$target_user" -r 2>/dev/null || true
            fi
        fi
        log "Rimossi job managed da crontab ${target_user}"
    done
}

show_status() {
    echo "=== Cron Jobs Gestiti ==="
    echo ""
    for target_user in root REDACTED_HOSTNAME; do
        echo "--- ${target_user} ---"
        if [ "$target_user" = "root" ]; then
            crontab -l 2>/dev/null | grep -F "$TAG" || echo "  (nessuno)"
        else
            crontab -u "$target_user" -l 2>/dev/null | grep -F "$TAG" || echo "  (nessuno)"
        fi
        echo ""
    done
}

# --- Create the log cleanup script ---
create_cleanup_script() {
    cat > /mnt/nas2/nas-scripts/cleanup_logs.sh << 'CLEANUP'
#!/usr/bin/env bash
# =============================================================================
# CLEANUP LOGS — weekly log cleanup
# =============================================================================

LOG="/var/log/cleanup.log"
log() { echo "$(date -Is) - $*" >> "$LOG"; }

log "Inizio pulizia log"

# Journald: limit to 200MB
journalctl --vacuum-size=200M >> "$LOG" 2>&1 || true

# Rotate and compress old logs
find /var/log -name "*.log" -size +10M -exec truncate -s 0 {} \; 2>/dev/null
find /var/log -name "*.gz" -mtime +30 -delete 2>/dev/null
find /var/log -name "*.1" -mtime +14 -delete 2>/dev/null
find /var/log -name "*.old" -mtime +14 -delete 2>/dev/null

# Docker: prune container logs
docker system prune -f --volumes --filter "until=168h" >> "$LOG" 2>&1 || true

# Incus DNS log: rotate if > 1MB
if [ -f /var/log/incus-dns.log ] && [ "$(stat -f%z /var/log/incus-dns.log 2>/dev/null || stat -c%s /var/log/incus-dns.log 2>/dev/null)" -gt 1048576 ]; then
    mv /var/log/incus-dns.log /var/log/incus-dns.log.old
    log "Ruotato incus-dns.log"
fi

# apt cleanup
apt-get clean -y >> "$LOG" 2>&1 || true

log "Pulizia completata"
CLEANUP
    chmod +x /mnt/nas2/nas-scripts/cleanup_logs.sh
    log "Script cleanup_logs.sh creato"
}

# --- Main ---

if [ "$(id -u)" -ne 0 ]; then
    err "Esegui come root: sudo $0"
    exit 1
fi

case "${1:-install}" in
    install)
        log "Configurazione cron jobs..."
        create_cleanup_script

        for job in "${JOBS[@]}"; do
            IFS='|' read -r label schedule command target_user <<< "$job"
            install_managed_job "$label" "$schedule" "$command" "$target_user"
        done

        log "Cron jobs configurati"
        echo ""
        show_status
        ;;
    remove)
        remove_managed_jobs
        ;;
    status)
        show_status
        ;;
    *)
        echo "Uso: $0 {install|remove|status}"
        exit 1
        ;;
esac
