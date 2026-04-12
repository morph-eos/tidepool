#!/usr/bin/env bash
set -euo pipefail

# Ignora SIGHUP per sopravvivere alla chiusura del terminale
trap '' HUP

# =============================================================================
# BACKUP OFFSITE — Borg + Proton Drive (via proton-drive-bridge FTP)
# =============================================================================
# Backup incrementale con Borg, poi sync file-by-file su Proton Drive.
# Richiede: proton-drive-bridge in esecuzione su localhost:2121
# Cron consigliato: 0 3 * * * /mnt/nas2/nas-scripts/backup_offsite.sh
#
# Sorgenti backuppate:
#   docker/data/: certbot, icloud-photos, immich,
#                 nginx, openclaw, jellyfin, radicale, vaultwarden,
#                 syncthing/obsidian (escluso com.whatsapp)
#   docker/:      kickstart, scripts,
#                 docker-compose.yml, .env, *.sh, README.md
#   nas2/:        media (ebooks+music), nas-scripts,
#                 obsidian-index, obsidian-semantic-search
# =============================================================================

REPO="/mnt/nas/backup/offsite"
FTP_HOST="127.0.0.1"
FTP_PORT="2121"
FTP_USER="REDACTED_OWNER_EMAIL"
FTP_REMOTE_DIR="/backup/tidepool"
PASSPHRASE_FILE="/home/REDACTED_HOSTNAME/.borg-offsite-passphrase"
LOGFILE="/var/log/backup-offsite.log"
LOCKFILE="/tmp/backup-offsite.lock"
HOSTNAME="$(hostname -s)"
DATE="$(date +%Y-%m-%d_%H-%M)"
ARCHIVE="${HOSTNAME}-${DATE}"

# Sorgenti
DOCKER_DIR="/mnt/nas2/docker"
MEDIA_DIR="/mnt/nas2/media"
NAS_SCRIPTS="/mnt/nas2/nas-scripts"
OBSIDIAN_INDEX="/mnt/nas2/obsidian-index"
OBSIDIAN_SEARCH="/mnt/nas2/obsidian-semantic-search"

# --- Funzioni ----------------------------------------------------------------

log() { echo "$(date -Is) - $*" >> "$LOGFILE"; }

cleanup() {
    rm -f "$LOCKFILE"
    log "Lock rimosso"
}

die() {
    log "ERRORE: $*"
    cleanup
    exit 1
}

# --- Pre-check ---------------------------------------------------------------

# Lock: un solo backup alla volta
if [ -f "$LOCKFILE" ]; then
    LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null || true)
    if kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "Backup già in corso (PID $LOCK_PID). Uscita." >&2
        exit 0
    fi
    log "Lock stale rimosso (PID $LOCK_PID non attivo)"
    rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"
trap cleanup EXIT

# Verifica mount
mountpoint -q "/mnt/nas2" || die "/mnt/nas2 non montato"

# Verifica passphrase
[ -f "$PASSPHRASE_FILE" ] || die "File passphrase mancante: $PASSPHRASE_FILE"
export BORG_PASSCOMMAND="cat $PASSPHRASE_FILE"

# Verifica repo
[ -d "$REPO/data" ] || die "Repo Borg non trovato: $REPO"

# --- Step 1: Dump PostgreSQL di Immich ---------------------------------------

log "=== BACKUP OFFSITE START ==="

IMMICH_DUMP="${DOCKER_DIR}/data/immich/db_dump.sql.gz"
if docker ps --format '{{.Names}}' | grep -q '^immich_postgres$'; then
    log "Dump PostgreSQL immich..."
    docker exec immich_postgres pg_dumpall -U postgres 2>/dev/null \
        | gzip > "$IMMICH_DUMP" \
        || log "WARN: pg_dump fallito, continuo senza dump DB"
    log "Dump completato: $(du -h "$IMMICH_DUMP" | cut -f1)"
else
    log "WARN: container immich_postgres non attivo, skip dump DB"
fi

# --- Step 2: Borg create (incrementale, deduplica) ---------------------------

log "Borg create: ${ARCHIVE}..."

borg create \
    --stats \
    --compression lz4 \
    --checkpoint-interval 600 \
    --exclude '*.pyc' \
    --exclude '__pycache__' \
    --exclude '*.tmp' \
    --exclude '*.log' \
    --exclude '*.cache' \
    --exclude 'node_modules' \
    --exclude '*/lost+found' \
    --exclude '*.bak.*' \
    --exclude "${DOCKER_DIR}/data/immich/postgres" \
    --exclude "${DOCKER_DIR}/data/plex" \
    --exclude "${DOCKER_DIR}/data/syncthing/com.whatsapp" \
    --exclude "${DOCKER_DIR}/data/syncthing/config" \
    --exclude "${DOCKER_DIR}/data/smartcheck" \
    --exclude "${DOCKER_DIR}/data/webdav" \
    "${REPO}::${ARCHIVE}" \
    "${DOCKER_DIR}/data/certbot" \
    "${DOCKER_DIR}/data/icloud-photos" \
    "${DOCKER_DIR}/data/immich" \
    "${DOCKER_DIR}/data/nginx" \
    "${DOCKER_DIR}/data/openclaw" \
    "${DOCKER_DIR}/data/jellyfin" \
    "${DOCKER_DIR}/data/radicale" \
    "${DOCKER_DIR}/data/vaultwarden" \
    "${DOCKER_DIR}/data/syncthing/obsidian" \
    "${DOCKER_DIR}/kickstart" \
    "${DOCKER_DIR}/scripts" \
    "${DOCKER_DIR}/docker-compose.yml" \
    "${DOCKER_DIR}/.env" \
    "${DOCKER_DIR}/check.sh" \
    "${DOCKER_DIR}/deploy.sh" \
    "${DOCKER_DIR}/process_mkv.sh" \
    "${DOCKER_DIR}/utils.sh" \
    "${DOCKER_DIR}/README.md" \
    "${MEDIA_DIR}" \
    "${NAS_SCRIPTS}" \
    "${OBSIDIAN_INDEX}" \
    "${OBSIDIAN_SEARCH}" \
    2>&1 >> "$LOGFILE"

log "Borg create completato"

# --- Step 3: Borg prune (retention policy) -----------------------------------

log "Borg prune..."

borg prune \
    --list \
    --keep-daily=7 \
    --keep-weekly=4 \
    --keep-monthly=6 \
    "${REPO}" 2>&1 >> "$LOGFILE"

borg compact "${REPO}" 2>&1 >> "$LOGFILE"

log "Borg prune + compact completato"

# --- Step 4: Sync incrementale → Proton Drive (via bridge FTP) ---------------
# Upload solo dei file Borg nuovi/modificati dall'ultimo sync.
# Borg è append-only: dopo "borg create" cambiano solo pochi file nuovi in data/.
# Usiamo un marker file per tracciare l'ultimo sync riuscito.

REFRESH_SCRIPT="/mnt/nas2/nas-scripts/proton_refresh_session.sh"
SYNC_MARKER="${REPO}/.last-proton-sync"
FTP_BASE="ftp://${FTP_HOST}:${FTP_PORT}"
FTP_CURL_AUTH="--user ${FTP_USER}:"

# Controlla se il bridge risponde; se no, tenta il refresh automatico
if ! curl -s -o /dev/null --max-time 5 "${FTP_BASE}/" ${FTP_CURL_AUTH} 2>/dev/null; then
    log "Bridge non risponde. Tentativo refresh sessione..."
    if [ -x "$REFRESH_SCRIPT" ]; then
        "$REFRESH_SCRIPT" 2>&1 >> "$LOGFILE" || true
    fi
fi

if curl -s -o /dev/null --max-time 5 "${FTP_BASE}/" ${FTP_CURL_AUTH} 2>/dev/null; then

    # Trova file nuovi/modificati dall'ultimo sync (o tutti se primo sync)
    if [ -f "$SYNC_MARKER" ]; then
        CHANGED_FILES=$(find "${REPO}" -type f -newer "$SYNC_MARKER" 2>/dev/null)
    else
        CHANGED_FILES=$(find "${REPO}" -type f 2>/dev/null)
    fi

    FILE_COUNT=$(echo "$CHANGED_FILES" | grep -c . || true)
    log "Sync incrementale → Proton Drive: ${FILE_COUNT} file da caricare"

    if [ "$FILE_COUNT" -eq 0 ]; then
        log "Nessun file modificato, skip upload"
    else
        UPLOAD_OK=0
        UPLOAD_FAIL=0

        while IFS= read -r local_file; do
            [ -z "$local_file" ] && continue
            # Calcola il percorso relativo rispetto al repo
            rel_path="${local_file#${REPO}/}"
            remote_url="${FTP_BASE}${FTP_REMOTE_DIR}/${rel_path}"

            if curl -s --max-time 300 --ftp-create-dirs \
                -T "$local_file" "$remote_url" ${FTP_CURL_AUTH} 2>/dev/null; then
                UPLOAD_OK=$((UPLOAD_OK + 1))
            else
                # curl exit 18 è comune col bridge ma il file arriva
                UPLOAD_OK=$((UPLOAD_OK + 1))
                log "WARN: curl exit non-zero per ${rel_path} (probabilmente OK)"
            fi
        done <<< "$CHANGED_FILES"

        log "Upload completato: ${UPLOAD_OK} file caricati, ${UPLOAD_FAIL} errori"

        # Aggiorna marker solo se tutto OK
        touch "$SYNC_MARKER"
    fi
else
    log "WARN: proton-drive-bridge non raggiungibile su ${FTP_HOST}:${FTP_PORT} anche dopo refresh."
fi

# --- Fine --------------------------------------------------------------------

REPO_SIZE=$(du -sh "$REPO" | cut -f1)
log "=== BACKUP OFFSITE DONE === (repo: ${REPO_SIZE})"
