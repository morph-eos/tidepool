#!/usr/bin/env bash
# =============================================================================
# SETUP SYSTEMD WATCHDOG — email alert if PID1 stays "wedged"
# =============================================================================
# Closes the gap discovered on 11-14/09/2026 (see the README, pitfall "wedged
# systemd"): a kernel Oops during a container start/stop can leave
# systemd (PID1) stuck without panicking the kernel — hence without
# kdump/automatic reboot — and WITHOUT ANY ALERT. It stayed like that for 3 and a
# half days before being discovered by chance from a 502 on Immich.
#
# Installs systemd-health-watchdog.{service,timer}: runs systemd_watchdog.sh
# every 5 min, which detects the D-Bus timeout to PID1 and sends an email
# (shared SMTP from .env) — it does not reboot by itself (see the rationale in
# the script itself: a forced reboot skips the orderly sync of the DBs).
#
# Idempotent. Usage:
#   sudo bash setup_systemd_watchdog.sh          # install/update
#   sudo bash setup_systemd_watchdog.sh status   # show status
#   sudo bash setup_systemd_watchdog.sh test     # run a check right away
#   sudo bash setup_systemd_watchdog.sh remove   # uninstall
# =============================================================================
set -euo pipefail

[[ $EUID -ne 0 ]] && exec sudo "$0" "$@"

ACTION="${1:-install}"
SCRIPTS_DIR="/mnt/nas2/nas-scripts"
SYSD="/etc/systemd/system"
WATCHDOG_SCRIPT="$SCRIPTS_DIR/systemd_watchdog.sh"

log()  { echo "[systemd-watchdog-setup] $*"; }
warn() { echo "[systemd-watchdog-setup] WARN: $*" >&2; }

write_unit() {
    local path="$1"; shift
    local content="$1"
    local tmp; tmp=$(mktemp)
    printf '%s' "$content" > "$tmp"
    if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"
        return 1
    fi
    install -m 644 "$tmp" "$path"
    rm -f "$tmp"
    return 0
}

do_install() {
    if [[ ! -x "$WATCHDOG_SCRIPT" ]]; then
        warn "Script $WATCHDOG_SCRIPT non trovato o non eseguibile"
        return 1
    fi

    local svc_changed=0 timer_changed=0
    write_unit "$SYSD/systemd-health-watchdog.service" "$(cat <<UNIT
[Unit]
Description=Rileva PID1 wedged (D-Bus non risponde) e manda alert email

[Service]
Type=oneshot
ExecStart=$WATCHDOG_SCRIPT
UNIT
)" && svc_changed=1

    write_unit "$SYSD/systemd-health-watchdog.timer" "$(cat <<'UNIT'
[Unit]
Description=Esegue systemd-health-watchdog ogni 5 min

[Timer]
OnBootSec=120
OnUnitActiveSec=5min
Unit=systemd-health-watchdog.service

[Install]
WantedBy=timers.target
UNIT
)" && timer_changed=1

    if (( svc_changed || timer_changed )); then
        log "Unit aggiornate, daemon-reload"
        systemctl daemon-reload
    fi
    systemctl enable --now systemd-health-watchdog.timer >/dev/null
    log "OK ($(systemctl is-active systemd-health-watchdog.timer))"
}

show_status() {
    echo "=== systemd-health-watchdog ==="
    printf '  %-40s %s\n' "systemd-health-watchdog.timer" "$(systemctl is-active systemd-health-watchdog.timer 2>&1)"
    echo
    systemctl list-timers systemd-health-watchdog.timer --no-pager 2>&1 | head -4
    echo
    if [[ -f /var/lib/systemd-health-watchdog/wedged-since ]]; then
        echo "  STATO: wedged dal $(date -d @"$(cat /var/lib/systemd-health-watchdog/wedged-since)" '+%d/%m/%Y %H:%M')"
    else
        echo "  STATO: nessun problema rilevato"
    fi
}

do_test() {
    log "Esecuzione manuale di systemd_watchdog.sh"
    "$WATCHDOG_SCRIPT"
}

do_remove() {
    log "Disinstallazione"
    systemctl disable --now systemd-health-watchdog.timer 2>/dev/null || true
    rm -f "$SYSD/systemd-health-watchdog.service" "$SYSD/systemd-health-watchdog.timer"
    rm -rf /var/lib/systemd-health-watchdog
    systemctl daemon-reload
    log "Rimosso (script $WATCHDOG_SCRIPT NON toccato)"
}

case "$ACTION" in
    install|update|"")
        do_install
        echo
        show_status
        ;;
    status)
        show_status
        ;;
    test)
        do_test
        ;;
    remove|uninstall)
        do_remove
        ;;
    *)
        echo "Uso: $0 [install|status|test|remove]" >&2
        exit 1
        ;;
esac
