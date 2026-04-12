#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# BACKUP OFFSITE — Script di ripristino
# =============================================================================
# Ripristina file dal repository Borg (locale o scaricato da Proton Drive).
#
# Uso:
#   ./backup_restore.sh list                       — Mostra tutti gli archivi
#   ./backup_restore.sh info <archivio>            — Dettagli di un archivio
#   ./backup_restore.sh ls <archivio> [percorso]   — Lista file in un archivio
#   ./backup_restore.sh extract <archivio> <dest> [percorso...]
#                                                  — Estrai file
#   ./backup_restore.sh download                   — Scarica repo da Proton Drive
#   ./backup_restore.sh restore-immich-db          — Ripristina DB Immich
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

REPO="/mnt/nas/backup/offsite"
PASSPHRASE_FILE="$HOME/.borg-offsite-passphrase"
FTP_HOST="127.0.0.1"
FTP_PORT="2121"
FTP_USER="REDACTED_OWNER_EMAIL"
FTP_REMOTE_DIR="/backup/tidepool"

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $*"; }

# Verifica passphrase
check_passphrase() {
    if [ ! -f "$PASSPHRASE_FILE" ]; then
        err "File passphrase mancante: $PASSPHRASE_FILE
Inseriscila manualmente:
  echo 'LA_TUA_PASSPHRASE' > $PASSPHRASE_FILE
  chmod 600 $PASSPHRASE_FILE"
    fi
    export BORG_PASSCOMMAND="cat $PASSPHRASE_FILE"
}

# Verifica che il repo esista
check_repo() {
    if [ ! -d "$REPO/data" ]; then
        err "Repository Borg non trovato in $REPO
Se il disco è stato riformattato, scarica prima il repo da Proton Drive:
  $0 download"
    fi
}

# Download ricorsivo da FTP via curl (il bridge non supporta lftp mirror)
ftp_download_recursive() {
    local remote_dir="$1"
    local local_dir="$2"
    local ftp_url="ftp://${FTP_HOST}:${FTP_PORT}"
    local auth="--user ${FTP_USER}:"

    mkdir -p "$local_dir"

    # Lista directory remota
    local listing
    listing=$(curl -s --max-time 30 "${ftp_url}${remote_dir}/" ${auth} 2>/dev/null) || return 1

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local name
        name=$(echo "$line" | awk '{print $NF}')
        [ -z "$name" ] && continue
        [[ "$name" == "." || "$name" == ".." ]] && continue

        if echo "$line" | grep -q '^d'; then
            # Directory: recurse
            ftp_download_recursive "${remote_dir}/${name}" "${local_dir}/${name}"
        else
            # File: download
            info "  ↓ ${remote_dir}/${name}"
            curl -s --max-time 300 \
                -o "${local_dir}/${name}" \
                "${ftp_url}${remote_dir}/${name}" \
                ${auth} 2>/dev/null || true
        fi
    done <<< "$listing"
}

# =============================================================================
# Comandi
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
    echo ""
    info "Scarica il repository Borg da Proton Drive"
    echo ""

    # Verifica che il bridge sia attivo
    if ! curl -s -o /dev/null --max-time 5 "ftp://${FTP_HOST}:${FTP_PORT}/" --user "${FTP_USER}:" 2>/dev/null; then
        warn "proton-drive-bridge non attivo."
        info "Avvialo con: sudo systemctl start proton-drive-bridge"
        info "Oppure esegui: /mnt/nas2/nas-scripts/proton_refresh_session.sh"
        err "Bridge non raggiungibile su ${FTP_HOST}:${FTP_PORT}"
    fi

    mkdir -p "$REPO"

    info "Contenuto remoto su Proton Drive:"
    curl -s --max-time 15 "ftp://${FTP_HOST}:${FTP_PORT}${FTP_REMOTE_DIR}/" --user "${FTP_USER}:" 2>/dev/null || true
    echo ""

    info "Download ricorsivo da Proton Drive → ${REPO}..."
    info "Questo potrebbe richiedere molto tempo a seconda della dimensione..."
    echo ""

    ftp_download_recursive "${FTP_REMOTE_DIR}" "${REPO}"

    if [ ! -d "$REPO/data" ]; then
        err "Download fallito: directory data/ non trovata in $REPO"
    fi

    log "Download completato: $(du -sh "$REPO" | cut -f1)"

    # Verifica integrità
    check_passphrase
    export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
    info "Verifica integrità repo..."
    if borg check "$REPO" 2>&1; then
        log "Repository integro"
    else
        warn "Problemi di integrità rilevati. Controlla i log."
    fi
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
        gunzip -c "$dump_file" | docker exec -i immich_postgres psql -U postgres 2>&1
        log "Database Immich ripristinato"
        info "Riavvia Immich: docker compose -f /mnt/nas2/docker/docker-compose.yml restart immich_server"
    else
        err "Container immich_postgres non attivo. Avvialo prima del restore."
    fi

    rm -rf "$tmp_dir"
}

# =============================================================================
# Guida rapida
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
║       sudo apt install borgbackup lftp expect gnome-keyring       ║
║                         dbus-x11 python3                          ║
║  2. Crea file passphrase:                                         ║
║       echo 'PASSPHRASE' > ~/.borg-offsite-passphrase              ║
║       chmod 600 ~/.borg-offsite-passphrase                        ║
║  3. Installa proton-drive-bridge + configura servizio:            ║
║       ./backup_setup.sh                                           ║
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
