#!/usr/bin/env bash
# =============================================================================
# SETUP HOST SERVICES — installa servizi systemd custom dell'host
# =============================================================================
# Idempotente. Installa:
#   1. wifi-watchdog.{service,timer}      → riconnette REDACTED_WIFI_IFACE se cade
#   2. nas-scripts-fixperms.{service,timer} → riapplica chmod 0775 su *.sh
#
# NON installa (gia' coperti da altri script):
#   - incus-* (setup_incus.sh)
#   - proton-drive-bridge.service (backup_setup.sh)
#   - cron jobs (setup_cron.sh)
#   - kdump (setup_kdump.sh, on-demand)
#
# Uso:
#   sudo bash setup_host_services.sh         # install/update
#   sudo bash setup_host_services.sh status  # mostra stato
#   sudo bash setup_host_services.sh remove  # disinstalla
# =============================================================================
set -euo pipefail

[[ $EUID -ne 0 ]] && exec sudo "$0" "$@"

ACTION="${1:-install}"
SCRIPTS_DIR="/mnt/nas2/nas-scripts"
SYSD="/etc/systemd/system"

log()  { echo "[host-services] $*"; }
warn() { echo "[host-services] WARN: $*" >&2; }

# ---------------------------------------------------------------------------
# Genera il contenuto di un unit file in modo idempotente.
# write_unit <path> <heredoc-content>
# Riscrive solo se il contenuto e' cambiato (preserva mtime).
# ---------------------------------------------------------------------------
write_unit() {
    local path="$1"; shift
    local content="$1"
    local tmp; tmp=$(mktemp)
    printf '%s' "$content" > "$tmp"
    if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"
        return 1   # 1 = nessun cambiamento
    fi
    install -m 644 "$tmp" "$path"
    rm -f "$tmp"
    return 0       # 0 = aggiornato
}

# ---------------------------------------------------------------------------
# Cleanup: rimuove la vecchia .path unit (sostituita da .timer)
# ---------------------------------------------------------------------------
cleanup_legacy() {
    if [[ -f "$SYSD/nas-scripts-fixperms.path" ]]; then
        log "Cleanup unit legacy: nas-scripts-fixperms.path"
        systemctl disable --now nas-scripts-fixperms.path 2>/dev/null || true
        rm -f "$SYSD/nas-scripts-fixperms.path"
    fi
}

# ---------------------------------------------------------------------------
# 1. WiFi watchdog
# ---------------------------------------------------------------------------
install_wifi_watchdog() {
    log "[1/2] WiFi watchdog (wifi-watchdog.timer)"
    local script="$SCRIPTS_DIR/wifi_watchdog.sh"
    if [[ ! -x "$script" ]]; then
        warn "Script $script non trovato o non eseguibile"
        return 1
    fi
    local svc_changed=0 timer_changed=0
    write_unit "$SYSD/wifi-watchdog.service" "$(cat <<UNIT
[Unit]
Description=WiFi Watchdog — riconnette REDACTED_WIFI_IFACE se cade (es. modem riavviato)
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=$script
UNIT
)" && svc_changed=1
    write_unit "$SYSD/wifi-watchdog.timer" "$(cat <<UNIT
[Unit]
Description=Esegue wifi-watchdog ogni 60s

[Timer]
OnBootSec=120
OnUnitActiveSec=60
Unit=wifi-watchdog.service

[Install]
WantedBy=timers.target
UNIT
)" && timer_changed=1
    if (( svc_changed || timer_changed )); then
        log "  Unit aggiornate, daemon-reload"
        systemctl daemon-reload
    fi
    systemctl enable --now wifi-watchdog.timer >/dev/null
    log "  OK ($(systemctl is-active wifi-watchdog.timer))"
}

# ---------------------------------------------------------------------------
# 2. nas-scripts-fixperms (riapplica +x ogni 5 min)
# ---------------------------------------------------------------------------
install_fixperms() {
    log "[2/2] nas-scripts-fixperms (timer ogni 5 min)"
    local svc_changed=0 timer_changed=0
    write_unit "$SYSD/nas-scripts-fixperms.service" "$(cat <<'UNIT'
[Unit]
Description=Restore +x on /mnt/nas2/nas-scripts/*.sh

[Service]
Type=oneshot
ExecStart=/usr/bin/find /mnt/nas2/nas-scripts -maxdepth 1 -name *.sh -exec chmod 0775 {} +
UNIT
)" && svc_changed=1
    write_unit "$SYSD/nas-scripts-fixperms.timer" "$(cat <<'UNIT'
[Unit]
Description=Re-applica permessi 0775 a /mnt/nas2/nas-scripts/*.sh ogni 5 min

[Timer]
OnBootSec=60
OnUnitActiveSec=5min
Unit=nas-scripts-fixperms.service

[Install]
WantedBy=timers.target
UNIT
)" && timer_changed=1
    if (( svc_changed || timer_changed )); then
        log "  Unit aggiornate, daemon-reload"
        systemctl daemon-reload
    fi
    # Esegui subito per fissare i permessi
    systemctl start nas-scripts-fixperms.service >/dev/null
    systemctl enable --now nas-scripts-fixperms.timer >/dev/null
    log "  OK ($(systemctl is-active nas-scripts-fixperms.timer))"
}

# ---------------------------------------------------------------------------
# Stato
# ---------------------------------------------------------------------------
show_status() {
    echo "=== Host services custom (gestiti da setup_host_services.sh) ==="
    for u in wifi-watchdog.timer nas-scripts-fixperms.timer; do
        printf '  %-40s %s\n' "$u" "$(systemctl is-active "$u" 2>&1)"
    done
    echo
    echo "=== Ultime esecuzioni ==="
    systemctl list-timers wifi-watchdog.timer nas-scripts-fixperms.timer --no-pager 2>&1 | head -5
    echo
    echo "=== Altri servizi custom (gestiti altrove) ==="
    for u in incus-dns-sync.timer incus-iptables.service proton-drive-bridge.service; do
        if systemctl list-unit-files "$u" >/dev/null 2>&1; then
            printf '  %-40s %s  (vedi %s)\n' "$u" \
                "$(systemctl is-active "$u" 2>&1)" \
                "$([[ $u == incus* ]] && echo setup_incus.sh || echo backup_setup.sh)"
        fi
    done
}

# ---------------------------------------------------------------------------
# Remove
# ---------------------------------------------------------------------------
do_remove() {
    log "Disinstallazione servizi custom"
    for u in wifi-watchdog.timer wifi-watchdog.service \
             nas-scripts-fixperms.timer nas-scripts-fixperms.service \
             nas-scripts-fixperms.path; do
        systemctl disable --now "$u" 2>/dev/null || true
        rm -f "$SYSD/$u"
    done
    systemctl daemon-reload
    log "Rimossi (script e configurazioni *.sh in $SCRIPTS_DIR NON toccati)"
}

# ---------------------------------------------------------------------------
case "$ACTION" in
    install|update|"")
        cleanup_legacy
        install_wifi_watchdog
        install_fixperms
        echo
        show_status
        ;;
    status)
        show_status
        ;;
    remove|uninstall)
        do_remove
        ;;
    *)
        echo "Uso: $0 [install|status|remove]" >&2
        exit 1
        ;;
esac
