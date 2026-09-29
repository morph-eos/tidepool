#!/usr/bin/env bash
# =============================================================================
# SETUP HOST SERVICES — installs the host's custom systemd services
# =============================================================================
# Idempotent. Installs:
#   1. wifi-watchdog.{service,timer}      → reconnects REDACTED_WIFI_IFACE if it drops
#   2. nas-scripts-fixperms.{service,timer} → reapplies chmod 0775 on the *.sh of
#      nas-scripts/ and docker/ (Samba/macOS clears the +x bit)
#   3. docker-ensure-containers.service   → restarts Docker containers left
#      exited/created after boot (/mnt/nas2 mount not ready when
#      dockerd starts), EXCLUDING the ones intentionally stopped (certbot, icloud;
#      see DOCKER_ENSURE_EXCLUDE)
#
# Does NOT install (already covered by other scripts):
#   - incus-* (setup_incus.sh)
#   - cron jobs (setup_cron.sh)
#   - kdump (setup_kdump.sh, on demand)
#
# Usage:
#   sudo bash setup_host_services.sh         # install/update
#   sudo bash setup_host_services.sh status  # show status
#   sudo bash setup_host_services.sh remove  # uninstall
# =============================================================================
set -euo pipefail

[[ $EUID -ne 0 ]] && exec sudo "$0" "$@"

ACTION="${1:-install}"
SCRIPTS_DIR="/mnt/nas2/nas-scripts"
SYSD="/etc/systemd/system"

# Containers that must NEVER be auto-restarted by docker-ensure-containers even if
# they are exited/created at boot: run-once (certbot, icloud) or intentionally
# paused (see docker-compose.yml profiles). Add here any new
# "activatable"/manually paused services.
DOCKER_ENSURE_EXCLUDE='certbot\|icloud'

log()  { echo "[host-services] $*"; }
warn() { echo "[host-services] WARN: $*" >&2; }

# ---------------------------------------------------------------------------
# Generates the content of a unit file idempotently.
# write_unit <path> <heredoc-content>
# Rewrites only if the content changed (preserves mtime).
# ---------------------------------------------------------------------------
write_unit() {
    local path="$1"; shift
    local content="$1"
    local tmp; tmp=$(mktemp)
    printf '%s' "$content" > "$tmp"
    if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"
        return 1   # 1 = no change
    fi
    install -m 644 "$tmp" "$path"
    rm -f "$tmp"
    return 0       # 0 = updated
}

# ---------------------------------------------------------------------------
# Cleanup: removes the old .path unit (replaced by .timer)
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
    log "[1/3] WiFi watchdog (wifi-watchdog.timer)"
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
# 2. nas-scripts-fixperms (reapplies +x every 5 min)
# ---------------------------------------------------------------------------
install_fixperms() {
    log "[2/3] nas-scripts-fixperms (timer ogni 5 min)"
    local svc_changed=0 timer_changed=0
    write_unit "$SYSD/nas-scripts-fixperms.service" "$(cat <<'UNIT'
[Unit]
Description=Restore +x on /mnt/nas2/nas-scripts/*.sh and /mnt/nas2/docker/**/*.sh

[Service]
Type=oneshot
ExecStart=/usr/bin/find /mnt/nas2/nas-scripts /mnt/nas2/docker -maxdepth 2 -name '*.sh' -not -path '*/data/*' -exec chmod 0775 {} +
UNIT
)" && svc_changed=1
    write_unit "$SYSD/nas-scripts-fixperms.timer" "$(cat <<'UNIT'
[Unit]
Description=Re-applica permessi 0775 agli script di nas-scripts e docker ogni 5 min

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
    # Run right away to fix the permissions
    systemctl start nas-scripts-fixperms.service >/dev/null
    systemctl enable --now nas-scripts-fixperms.timer >/dev/null
    log "  OK ($(systemctl is-active nas-scripts-fixperms.timer))"
}

# ---------------------------------------------------------------------------
# 3. docker-ensure-containers (restarts exited/created containers after boot,
#    excluding the ones in DOCKER_ENSURE_EXCLUDE)
# ---------------------------------------------------------------------------
install_docker_ensure_containers() {
    log "[3/3] docker-ensure-containers.service (esclude: $DOCKER_ENSURE_EXCLUDE)"
    local svc_changed=0
    write_unit "$SYSD/docker-ensure-containers.service" "$(cat <<UNIT
[Unit]
Description=Ensure Docker containers are running after mounts
After=docker.service mnt-nas.mount mnt-nas2.mount
Requires=docker.service
ConditionPathIsMountPoint=/mnt/nas2

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 10
ExecStart=/bin/bash -c 'stopped=\$(docker ps -a --filter "status=exited" --filter "status=created" --format "{{.Names}}" | grep -v "$DOCKER_ENSURE_EXCLUDE"); if [ -n "\$stopped" ]; then echo "Riavvio container fermi: \$stopped"; echo "\$stopped" | xargs docker start; else echo "Tutti i container sono già running"; fi'

[Install]
WantedBy=multi-user.target
UNIT
)" && svc_changed=1
    if (( svc_changed )); then
        log "  Unit aggiornata, daemon-reload"
        systemctl daemon-reload
    fi
    systemctl enable --now docker-ensure-containers.service >/dev/null
    log "  OK ($(systemctl is-active docker-ensure-containers.service))"
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
show_status() {
    echo "=== Host services custom (gestiti da setup_host_services.sh) ==="
    for u in wifi-watchdog.timer nas-scripts-fixperms.timer docker-ensure-containers.service; do
        printf '  %-40s %s\n' "$u" "$(systemctl is-active "$u" 2>&1)"
    done
    echo
    echo "=== Ultime esecuzioni ==="
    systemctl list-timers wifi-watchdog.timer nas-scripts-fixperms.timer --no-pager 2>&1 | head -5
    echo
    echo "=== Altri servizi custom (gestiti altrove) ==="
    for u in incus-dns-sync.timer incus-iptables.service; do
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
             nas-scripts-fixperms.path docker-ensure-containers.service; do
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
        install_docker_ensure_containers
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
