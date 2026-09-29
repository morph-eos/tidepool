#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# SETUP RECONFIGURE — convenient orchestrator to reconfigure REDACTED_BRAND
# =============================================================================

SCRIPTS_DIR="/mnt/nas2/nas-scripts"

log() { echo "[reconfigure] $*"; }
run() { log "$*"; "$@"; }

require_root() {
    [ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
}

install_all() {
    run bash "$SCRIPTS_DIR/setup_host_services.sh" install
    run bash "$SCRIPTS_DIR/setup_cron.sh" install
    run bash "$SCRIPTS_DIR/setup_samba.sh"
    run bash "$SCRIPTS_DIR/setup_mail.sh" install
    run bash "$SCRIPTS_DIR/setup_nextcloud_oidc.sh" install
}

status_all() {
    run bash "$SCRIPTS_DIR/setup_host_services.sh" status
    run bash "$SCRIPTS_DIR/setup_cron.sh" status
    run bash "$SCRIPTS_DIR/setup_mail.sh" status
    run bash "$SCRIPTS_DIR/setup_nextcloud_oidc.sh" status
}

usage() {
    cat <<USAGE
Uso: $0 {install|status}

install  Riconcilia servizi host, cron, Samba, mail, OIDC Nextcloud
status   Mostra stato sintetico delle configurazioni principali

Nota: setup dischi, Incus, kdump e backup Proton restano script dedicati
perché hanno prerequisiti o rischi operativi propri.
USAGE
}

require_root "$@"
case "${1:-install}" in
    install) install_all ;;
    status) status_all ;;
    *) usage; exit 1 ;;
esac