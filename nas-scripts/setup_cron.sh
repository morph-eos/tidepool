#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# SETUP CRON — Configura cron jobs in modo idempotente
# =============================================================================
# Ogni job è identificato da un tag univoco nel commento.
# Lo script aggiunge/aggiorna solo i job con il proprio tag,
# senza toccare gli altri cronjob esistenti.
#
# Uso:
#   sudo bash /mnt/nas2/nas-scripts/setup_cron.sh          # installa/aggiorna
#   sudo bash /mnt/nas2/nas-scripts/setup_cron.sh remove    # rimuove solo i job gestiti
#   sudo bash /mnt/nas2/nas-scripts/setup_cron.sh status    # mostra stato
# =============================================================================

TAG="# [managed:nas-scripts]"
DOCKER_DIR="/mnt/nas2/docker"

# Colori
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[CRON]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Job definitions ---
# Formato: LABEL|SCHEDULE|COMMAND|USER (root o user)
# SCHEDULE usa crontab syntax
JOBS=(
    # Restart certbot settimanale (ogni 7 giorni, offset 3 per non collidere con cleanup)
    "certbot-restart|0 5 */7 * *|cd ${DOCKER_DIR} && docker compose restart certbot 2>/dev/null|user"
    # Reload cert LE in Incus (symlink, basta restart — 30 min dopo certbot)
    "incus-cert-sync|30 5 */7 * *|systemctl restart incus|root"
    # Log cleanup settimanale (offset diverso)
    "log-cleanup|0 4 */7 * *|/mnt/nas2/nas-scripts/cleanup_logs.sh|root"
    # Backup quotidiano: offsite alle 03:00 (dump+borg create, ~1min), poi Proton
    # Drive mirror via timer utente (03:30, vedi setup_proton_cli_backup.sh).
    # borg_backup_nas2.sh e' STACCATO alle 04:00 (non piu' incatenato con ';'):
    # scansiona tutto /mnt/nas2 (piu' pesante, durata non garantita <30min) e
    # sovrapporsi al mirror Proton (stesso disco /mnt/nas) ha causato contesa
    # I/O -> soft lockup ext4 il 2026-07-04 (vedi README, sezione Pitfall). REDACTED_DRIVE_TC gira
    # comunque ogni notte a prescindere dall'esito di backup_offsite.sh.
    "backup-offsite|0 3 * * *|sudo /mnt/nas2/nas-scripts/backup_offsite.sh|user"
    "backup-nas2-REDACTED_DRIVE|0 4 * * *|sudo /mnt/nas2/nas-scripts/borg_backup_nas2.sh|user"
)

# --- Funzioni ---

install_managed_job() {
    local label="$1" schedule="$2" command="$3" target_user="$4"
    local cron_line="${schedule} ${command} ${TAG} ${label}"

    local current_crontab
    if [ "$target_user" = "root" ]; then
        current_crontab=$(crontab -l 2>/dev/null || true)
    else
        current_crontab=$(crontab -u REDACTED_HOSTNAME -l 2>/dev/null || true)
    fi

    # Rimuovi vecchia entry con stesso label (se esiste)
    local filtered
    filtered=$(echo "$current_crontab" | grep -Fv "${TAG} ${label}" || true)

    # Rimuovi anche entry non-taggate che matchano lo stesso comando (migrazione)
    filtered=$(echo "$filtered" | grep -v "$(echo "$command" | sed 's/[.*+?^${}()|[\]/\\&/g')" || true)

    # Aggiungi la nuova entry
    local new_crontab
    if [ -n "$filtered" ]; then
        new_crontab="${filtered}"$'\n'"${cron_line}"
    else
        new_crontab="${cron_line}"
    fi

    # Rimuovi righe vuote in eccesso e commenti orfani
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

# --- Crea lo script di cleanup log ---
create_cleanup_script() {
    cat > /mnt/nas2/nas-scripts/cleanup_logs.sh << 'CLEANUP'
#!/usr/bin/env bash
# =============================================================================
# CLEANUP LOGS — Pulizia settimanale log
# =============================================================================

LOG="/var/log/cleanup.log"
log() { echo "$(date -Is) - $*" >> "$LOG"; }

log "Inizio pulizia log"

# Journald: limita a 200MB
journalctl --vacuum-size=200M >> "$LOG" 2>&1 || true

# Ruota e comprimi log vecchi
find /var/log -name "*.log" -size +10M -exec truncate -s 0 {} \; 2>/dev/null
find /var/log -name "*.gz" -mtime +30 -delete 2>/dev/null
find /var/log -name "*.1" -mtime +14 -delete 2>/dev/null
find /var/log -name "*.old" -mtime +14 -delete 2>/dev/null

# Docker: prune log container
docker system prune -f --volumes --filter "until=168h" >> "$LOG" 2>&1 || true

# Incus DNS log: ruota se > 1MB
if [ -f /var/log/incus-dns.log ] && [ "$(stat -f%z /var/log/incus-dns.log 2>/dev/null || stat -c%s /var/log/incus-dns.log 2>/dev/null)" -gt 1048576 ]; then
    mv /var/log/incus-dns.log /var/log/incus-dns.log.old
    log "Ruotato incus-dns.log"
fi

# Pulizia apt
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
