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
