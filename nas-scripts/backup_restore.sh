#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# OFFSITE BACKUP — restore script
# =============================================================================
# Restores files from the Borg repository (local or downloaded from Proton Drive).
#
# Usage:
#   ./backup_restore.sh list                       — Show all archives
#   ./backup_restore.sh info <archive>             — Details of an archive
#   ./backup_restore.sh ls <archive> [path]        — List files in an archive
#   ./backup_restore.sh extract <archive> <dest> [path...]
#                                                  — Extract files
#   ./backup_restore.sh download                   — Download the repo from Proton Drive
#   ./backup_restore.sh restore-immich-db          — Restore the Immich DB
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

REPO="/mnt/nas/backup/offsite"
PASSPHRASE_FILE="$HOME/.borg-offsite-passphrase"

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $*"; }

# Check the passphrase
check_passphrase() {
    if [ ! -f "$PASSPHRASE_FILE" ]; then
        err "File passphrase mancante: $PASSPHRASE_FILE
Inseriscila manualmente:
  echo 'LA_TUA_PASSPHRASE' > $PASSPHRASE_FILE
  chmod 600 $PASSPHRASE_FILE"
    fi
    export BORG_PASSCOMMAND="cat $PASSPHRASE_FILE"
}

# Check that the repo exists
check_repo() {
    if [ ! -d "$REPO/data" ]; then
        err "Repository Borg non trovato in $REPO
Se il disco è stato riformattato, scarica prima il repo da Proton Drive:
  $0 download"
    fi
}

# =============================================================================
# Commands
# =============================================================================

cmd_list() {
    check_passphrase
    check_repo
    echo ""
    info "Archivi disponibili in $REPO:"
    echo ""
    borg list "$REPO"
    echo ""
    info "Per vedere i dettagli: $0 info <nome-archivio>"
    info "Per estrarre:          $0 extract <nome-archivio> <directory-dest> [percorso...]"
}

cmd_info() {
    local archive="${1:-}"
    [ -z "$archive" ] && err "Uso: $0 info <nome-archivio>"
    check_passphrase
    check_repo
    borg info "${REPO}::${archive}"
}

cmd_ls() {
    local archive="${1:-}"
    [ -z "$archive" ] && err "Uso: $0 ls <nome-archivio> [percorso]"
    shift
    check_passphrase
    check_repo
    if [ $# -gt 0 ]; then
        borg list "${REPO}::${archive}" "$@"
    else
        borg list "${REPO}::${archive}"
    fi
}

cmd_extract() {
    local archive="${1:-}"
    local dest="${2:-}"
    [ -z "$archive" ] && err "Uso: $0 extract <nome-archivio> <directory-dest> [percorso...]"
    [ -z "$dest" ] && err "Specifica la directory di destinazione."
    shift 2

    check_passphrase
    check_repo

    mkdir -p "$dest"
    info "Estrazione dall'archivio: ${archive}"
    info "Destinazione: ${dest}"

    if [ $# -gt 0 ]; then
        info "Percorsi specifici: $*"
        (cd "$dest" && borg extract "${REPO}::${archive}" "$@")
    else
        warn "Estrai TUTTO l'archivio? (potrebbe essere molto grande)"
        read -rp "Continua? [y/N] " confirm
        [[ "$confirm" =~ ^[yY]$ ]] || { info "Annullato."; exit 0; }
        (cd "$dest" && borg extract "${REPO}::${archive}")
    fi

    log "Estrazione completata in: $dest"
}

cmd_download() {
    local PROTON_BIN=/usr/local/bin/proton-drive
    local REMOTE=/my-files/backup/tidepool
    local u=REDACTED_HOSTNAME uid; uid=$(id -u "$u")
    PD(){ sudo -u "$u" env XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" "$PROTON_BIN" "$@"; }
    echo ""
    info "Scarica il repository Borg da Proton Drive (CLI ufficiale)"
    echo ""
    [ -x "$PROTON_BIN" ] || err "proton-drive non installato (esegui setup_proton_cli_backup.sh)"
    PD filesystem list / >/dev/null 2>&1 || err "Proton non autenticato: come $u esegui 'proton-drive auth login' (GUI)"

    local parent; parent=$(dirname "$REPO")
    mkdir -p "$parent"
    info "Download ricorsivo $REMOTE -> $REPO (puo' richiedere molto tempo)..."
    PD filesystem download "$REMOTE" "$parent" || err "Download fallito"
    # filesystem download creates "<parent>/tidepool": normalize to $REPO
    if [ -d "$parent/tidepool/data" ] && [ "$parent/tidepool" != "$REPO" ]; then
        rm -rf "$REPO"; mv "$parent/tidepool" "$REPO"
    fi
    [ -d "$REPO/data" ] || err "Download fallito: data/ non trovata in $REPO"
    log "Download completato: $(du -sh "$REPO" | cut -f1)"

    check_passphrase
    export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
    info "Verifica integrità repo..."
    if borg check "$REPO" 2>&1; then log "Repository integro"; else warn "Problemi di integrità rilevati."; fi
}

cmd_restore_immich_db() {
    local archive="${1:-}"

    check_passphrase
    check_repo

    if [ -z "$archive" ]; then
        info "Archivi disponibili:"
        borg list "$REPO"
        echo ""
        read -rp "Nome archivio da cui ripristinare il DB: " archive
        [ -z "$archive" ] && err "Nessun archivio selezionato"
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local dump_path="mnt/nas2/docker/data/immich/db_dump.sql.gz"

    info "Estraggo il dump DB dall'archivio ${archive}..."
    (cd "$tmp_dir" && borg extract "${REPO}::${archive}" "$dump_path") || \
        err "Dump DB non trovato nell'archivio. Verifica con: $0 ls ${archive} | grep db_dump"

    local dump_file="${tmp_dir}/${dump_path}"
    [ -f "$dump_file" ] || err "File dump non trovato: $dump_file"

    info "Dimensione dump: $(du -h "$dump_file" | cut -f1)"
    warn "ATTENZIONE: Questo sovrascriverà il database Immich attuale!"
    read -rp "Continua? [y/N] " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || { rm -rf "$tmp_dir"; info "Annullato."; exit 0; }

    info "Ripristino database Immich..."
    if docker ps --format '{{.Names}}' | grep -q '^immich_postgres$'; then
        local db_user
        db_user=$(grep '^IMMICH_DB_USERNAME=' /mnt/nas2/docker/.env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d "\"'")
        gunzip -c "$dump_file" | docker exec -i immich_postgres psql -U "${db_user:-immich}" -d postgres 2>&1
        log "Database Immich ripristinato"
        info "Riavvia Immich: docker compose -f /mnt/nas2/docker/docker-compose.yml restart immich-server"
    else
        err "Container immich_postgres non attivo. Avvialo prima del restore."
    fi

    rm -rf "$tmp_dir"
}

# =============================================================================
# Quick guide
# =============================================================================

cmd_help() {
    cat <<'HELP'

╔═══════════════════════════════════════════════════════════════════╗
║              BACKUP OFFSITE — GUIDA AL RIPRISTINO                ║
╠═══════════════════════════════════════════════════════════════════╣
║                                                                   ║
║  PREREQUISITI                                                     ║
║  ───────────                                                      ║
║  • La passphrase Borg in ~/.borg-offsite-passphrase               ║
║  • Il repository Borg in /mnt/nas/backup/offsite/                 ║
║    (se perso, scaricalo prima con: ./backup_restore.sh download)  ║
║                                                                   ║
║  COMANDI                                                          ║
║  ────────                                                         ║
║  list                          Lista tutti gli archivi            ║
║  info  <archivio>              Dettagli di un archivio            ║
║  ls    <archivio> [percorso]   Lista file in un archivio          ║
║  extract <archivio> <dest> [percorso...]  Estrai file             ║
║  download                      Scarica repo da Proton Drive    ║
║  restore-immich-db [archivio]  Ripristina il database Immich      ║
║  help                          Questa guida                       ║
║                                                                   ║
║  ESEMPI                                                           ║
║  ──────                                                           ║
║  # Mostra tutti gli archivi                                       ║
║  ./backup_restore.sh list                                         ║
║                                                                   ║
║  # Estrai un singolo file di config                               ║
║  ./backup_restore.sh extract tidepool-2026-01-15_03-00 \           ║
║      /tmp/restore mnt/nas2/docker/docker-compose.yml              ║
║                                                                   ║
║  # Estrai tutta la cartella vaultwarden                           ║
║  ./backup_restore.sh extract tidepool-2026-01-15_03-00 \           ║
║      /tmp/restore mnt/nas2/docker/data/vaultwarden                ║
║                                                                   ║
║  # Estrai tutto l'archivio                                        ║
║  ./backup_restore.sh extract tidepool-2026-01-15_03-00 \           ║
║      /tmp/restore-full                                            ║
║                                                                   ║
║  # Ripristina il DB di Immich                                     ║
║  ./backup_restore.sh restore-immich-db                            ║
║                                                                   ║
║  # Disaster recovery: scarica repo da Proton Drive                ║
║  ./backup_restore.sh download                                     ║
║                                                                   ║
║  DISASTER RECOVERY (passo-passo)                                  ║
║  ───────────────────────────────                                  ║
║  1. Installa dipendenze:                                          ║
║     sudo apt install borgbackup gnome-keyring dbus-x11            ║
║       python3 curl                                                ║
║  2. Crea file passphrase:                                         ║
║       echo 'PASSPHRASE' > ~/.borg-offsite-passphrase              ║
║       chmod 600 ~/.borg-offsite-passphrase                        ║
║  3. Installa il CLI ufficiale Proton + timer + login:             ║
║       ./backup_setup.sh   poi:  proton-drive auth login           ║
║  4. Scarica il repo da Proton Drive:                              ║
║       ./backup_restore.sh download                                ║
║  5. Lista archivi e ripristina:                                   ║
║       ./backup_restore.sh list                                    ║
║       ./backup_restore.sh extract <archivio> /tmp/restore         ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝

HELP
}

# =============================================================================
# Main
# =============================================================================

case "${1:-help}" in
    list)               cmd_list ;;
    info)               shift; cmd_info "$@" ;;
    ls)                 shift; cmd_ls "$@" ;;
    extract)            shift; cmd_extract "$@" ;;
    download)           cmd_download ;;
    restore-immich-db)  shift; cmd_restore_immich_db "$@" ;;
    help|--help|-h)     cmd_help ;;
    *)                  err "Comando sconosciuto: $1. Usa '$0 help' per la guida." ;;
esac
