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
#                 nginx, openclaw, jellyfin, nextcloud (esc. db/),
#                 nextcloud-db-dumps, sqlite-snapshots, vaultwarden,
#                 syncthing/obsidian (escluso com.whatsapp)
#   docker/:      kickstart, scripts,
#                 docker-compose.yml, .env, *.sh, README.md
#   nas2/:        media (ebooks+music), nas-scripts,
#                 obsidian-index, obsidian-semantic-search
#
# Dump DB pre-borg:
#   - immich postgres -> data/immich/db_dump.sql.gz (overwrite ogni run)
#   - nextcloud mariadb -> data/nextcloud-db-dumps/nextcloud-N.sql.gz (rotazione 7gg)
#   - sqlite (vaultwarden, jellyfin, openclaw) -> data/sqlite-snapshots/ (lock-safe)
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
    send_backup_email "ERRORE backup offsite" \
        "Il backup offsite di $(hostname) è FALLITO il $(date '+%d/%m/%Y %H:%M')."$'\n'$'\n'"Errore: $*"$'\n'$'\n'"Controlla il log: /var/log/backup-offsite.log" 2>/dev/null || true
    cleanup
    exit 1
}

# Invia email di notifica (usa SMTP condiviso da .env, fallback SMART_*)
send_backup_email() {
    local subject="$1" body="$2"
    local env_file="/mnt/nas2/docker/.env"
    [ -f "$env_file" ] || { log "WARN: .env non trovato, email non inviata"; return 1; }

    env_get() { grep -E "^$1=" "$env_file" | tail -1 | cut -d= -f2- | sed -E 's/^"(.*)"$/\1/'; }

    local smtp_host smtp_port smtp_user smtp_pass smtp_from smtp_from_name smtp_to smtp_ssl smtp_tls smtp_url
    smtp_host=$(env_get SMTP_HOST || true); smtp_host=${smtp_host:-$(env_get SMART_SMTP_HOST || true)}
    smtp_port=$(env_get SMTP_PORT || true); smtp_port=${smtp_port:-$(env_get SMART_SMTP_PORT || true)}
    smtp_user=$(env_get SMTP_USERNAME || true); smtp_user=${smtp_user:-$(env_get SMART_SMTP_USERNAME || true)}
    smtp_pass=$(env_get SMTP_PASSWORD || true); smtp_pass=${smtp_pass:-$(env_get SMART_SMTP_PASSWORD || true)}
    smtp_from=$(env_get SMTP_FROM || true); smtp_from=${smtp_from:-$(env_get SMART_SMTP_FROM || true)}
    smtp_from_name=$(env_get SMTP_FROM_NAME || true); smtp_from_name=${smtp_from_name:-$(env_get SMART_SMTP_FROM_NAME || true)}
    smtp_ssl=$(env_get SMTP_SSL || true); smtp_ssl=${smtp_ssl:-$(env_get SMART_SMTP_SSL || true)}
    smtp_tls=$(env_get SMTP_EXPLICIT_TLS || true); smtp_tls=${smtp_tls:-$(env_get SMART_SMTP_EXPLICIT_TLS || true)}
    smtp_to=$(grep '^SMART_ALERT_EMAIL=' "$env_file" | cut -d= -f2)

    if [ -z "$smtp_host" ] || [ -z "$smtp_to" ]; then
        log "WARN: variabili SMTP incomplete, email non inviata"
        return 1
    fi

    if [ "$smtp_ssl" = "true" ]; then
        smtp_url="smtps://${smtp_host}:${smtp_port}"
    else
        smtp_url="smtp://${smtp_host}:${smtp_port}"
    fi

    local curl_tls=()
    [ "$smtp_ssl" = "true" ] || [ "$smtp_tls" = "true" ] && curl_tls=(--ssl-reqd)

    curl -s --max-time 30 --url "$smtp_url" \
        "${curl_tls[@]}" \
        --mail-from "$smtp_from" \
        --mail-rcpt "$smtp_to" \
        --user "${smtp_user}:${smtp_pass}" \
        -T - <<MAILEOF
From: ${smtp_from_name:-REDACTED_BRAND' Services} <${smtp_from}>
To: ${smtp_to}
Subject: [REDACTED_HOSTNAME backup] ${subject}
Content-Type: text/plain; charset=utf-8
Date: $(date -R)

${body}
MAILEOF
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        log "Email inviata: ${subject}"
    else
        log "WARN: invio email fallito (exit ${rc}): ${subject}"
    fi
    return $rc
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

# Trap per crash imprevisti (set -e): invia email prima di uscire
on_error() {
    local exit_code=$? lineno=${BASH_LINENO[0]}
    log "CRASH: script terminato inaspettatamente alla riga ${lineno} (exit ${exit_code})"
    send_backup_email "CRASH backup offsite" \
        "Il backup offsite di $(hostname) è CRASHATO il $(date '+%d/%m/%Y %H:%M')."$'\n'$'\n'"Riga: ${lineno} — Exit code: ${exit_code}"$'\n'$'\n'"Controlla il log: /var/log/backup-offsite.log" 2>/dev/null || true
}
trap on_error ERR

# Verifica mount
mountpoint -q "/mnt/nas2" || die "/mnt/nas2 non montato"

# Verifica passphrase
[ -f "$PASSPHRASE_FILE" ] || die "File passphrase mancante: $PASSPHRASE_FILE"
export BORG_PASSCOMMAND="cat $PASSPHRASE_FILE"

# Verifica repo
[ -d "$REPO/data" ] || die "Repo Borg non trovato: $REPO"

# --- Step 1a: Dump PostgreSQL di Immich --------------------------------------

log "=== BACKUP OFFSITE START ==="

IMMICH_DUMP="${DOCKER_DIR}/data/immich/db_dump.sql.gz"
if docker ps --format '{{.Names}}' | grep -q '^immich_postgres$'; then
    log "Dump PostgreSQL immich..."
    docker exec immich_postgres pg_dumpall -U postgres 2>/dev/null \
        | gzip > "$IMMICH_DUMP" \
        || log "WARN: pg_dump fallito, continuo senza dump DB"
    log "Dump immich: $(du -h "$IMMICH_DUMP" | cut -f1)"
else
    log "WARN: container immich_postgres non attivo, skip dump DB"
fi

# --- Step 1b: Dump MariaDB di Nextcloud --------------------------------------
# Il dump SQL è essenziale per restore consistente (i file binari MariaDB sotto
# data/nextcloud/db copiati a caldo possono essere corrotti). Tiene 7 dump
# rotanti per giorno della settimana (sovrascritti ogni settimana).

NC_DUMP_DIR="${DOCKER_DIR}/data/nextcloud-db-dumps"
mkdir -p "$NC_DUMP_DIR"
NC_DUMP="${NC_DUMP_DIR}/nextcloud-$(date +%u).sql.gz"  # 1=lun .. 7=dom
if docker ps --format '{{.Names}}' | grep -q '^nextcloud_mariadb$'; then
    log "Dump MariaDB nextcloud..."
    NC_DB_PASS=$(grep '^NEXTCLOUD_DB_ROOT_PASSWORD=' "${DOCKER_DIR}/.env" | cut -d= -f2-)
    if [ -n "$NC_DB_PASS" ]; then
        docker exec -e MYSQL_PWD="$NC_DB_PASS" nextcloud_mariadb \
            mariadb-dump --single-transaction --quick --lock-tables=false \
            -u root --all-databases 2>/dev/null \
            | gzip > "$NC_DUMP" \
            || log "WARN: mariadb-dump fallito, continuo senza dump DB nextcloud"
        log "Dump nextcloud: $(du -h "$NC_DUMP" | cut -f1) -> $(basename "$NC_DUMP")"
    else
        log "WARN: NEXTCLOUD_DB_ROOT_PASSWORD non trovato in .env, skip dump"
    fi
else
    log "WARN: container nextcloud_mariadb non attivo, skip dump DB"
fi

# --- Step 1c: Snapshot consistenti SQLite ------------------------------------
# vaultwarden, jellyfin, openclaw usano SQLite (WAL mode con scritture vive).
# Copiare il file a caldo può produrre DB corrotti. Usiamo `sqlite3 .backup`
# (host-side, lock-safe via WAL checkpoint). Richiede pacchetto sqlite3.

sqlite_snapshot() {
    local label="$1" src="$2" out="$3"
    if [ ! -f "$src" ]; then
        log "WARN: snapshot $label: file sorgente $src non trovato"
        return
    fi
    if ! command -v sqlite3 >/dev/null 2>&1; then
        log "WARN: sqlite3 non installato sull'host, skip snapshot $label"
        return
    fi
    if sqlite3 "$src" ".backup '$out'" 2>>"$LOGFILE"; then
        log "Snapshot $label: $(du -h "$out" | cut -f1)"
    else
        log "WARN: snapshot $label fallito"
    fi
}

SNAP_DIR="${DOCKER_DIR}/data/sqlite-snapshots"
mkdir -p "$SNAP_DIR"
sqlite_snapshot vaultwarden    "${DOCKER_DIR}/data/vaultwarden/db.sqlite3"           "${SNAP_DIR}/vaultwarden.sqlite3"
sqlite_snapshot jellyfin       "${DOCKER_DIR}/data/jellyfin/config/data/jellyfin.db" "${SNAP_DIR}/jellyfin.db"
sqlite_snapshot jellyfin-lib   "${DOCKER_DIR}/data/jellyfin/config/data/library.db"  "${SNAP_DIR}/jellyfin-library.db"
sqlite_snapshot openclaw-mem   "${DOCKER_DIR}/data/openclaw/memory/main.sqlite"      "${SNAP_DIR}/openclaw-main.sqlite"
sqlite_snapshot openclaw-runs  "${DOCKER_DIR}/data/openclaw/tasks/runs.sqlite"       "${SNAP_DIR}/openclaw-runs.sqlite"

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
    --exclude "${DOCKER_DIR}/data/nextcloud/db" \
    "${REPO}::${ARCHIVE}" \
    "${DOCKER_DIR}/data/certbot" \
    "${DOCKER_DIR}/data/icloud-photos" \
    "${DOCKER_DIR}/data/immich" \
    "${DOCKER_DIR}/data/nginx" \
    "${DOCKER_DIR}/data/openclaw" \
    "${DOCKER_DIR}/data/jellyfin" \
    "${DOCKER_DIR}/data/nextcloud" \
    "${DOCKER_DIR}/data/nextcloud-db-dumps" \
    "${DOCKER_DIR}/data/sqlite-snapshots" \
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
    >> "$LOGFILE" 2>&1 || BORG_RC=$?

BORG_RC=${BORG_RC:-0}
if [ "$BORG_RC" -ge 2 ]; then
    die "Borg create fallito con exit code $BORG_RC"
fi
[ "$BORG_RC" -eq 1 ] && log "WARN: Borg create terminato con warning (exit 1)"
log "Borg create completato"

# --- Step 3: Borg prune (retention policy) -----------------------------------

log "Borg prune..."

borg prune \
    --list \
    --keep-daily=7 \
    --keep-weekly=4 \
    --keep-monthly=6 \
    "${REPO}" >> "$LOGFILE" 2>&1 || true

borg compact "${REPO}" >> "$LOGFILE" 2>&1 || true

log "Borg prune + compact completato"

# --- Step 4: Sync verificato → Proton Drive (via bridge FTP) -----------------
# Strategia basata su manifest md5:
#   1. Calcola md5 di TUTTI i file locali in borg
#   2. Confronta con manifest (.proton-manifest: rel_path md5)
#   3. md5 diverso o assente → upload + ri-scarica e verifica md5
#   4. Solo se md5 post-download corrisponde → salva nel manifest
#   5. File nel manifest ma non più in locale → delete da Proton + manifest
# Il manifest è scritto atomicamente (tmp + mv) per resistere a interruzioni.
# Rate limit: 3 MB/s per upload e download.

REFRESH_SCRIPT="/mnt/nas2/nas-scripts/proton_refresh_session.sh"
MANIFEST="${REPO}/.proton-manifest"
FTP_BASE="ftp://${FTP_HOST}:${FTP_PORT}"
FTP_CURL_AUTH="--user ${FTP_USER}:"
RATE_LIMIT="3M"

# Controlla se il bridge risponde; se no, tenta il refresh automatico
if ! curl -s -o /dev/null --max-time 5 "${FTP_BASE}/" ${FTP_CURL_AUTH} 2>/dev/null; then
    log "Bridge non risponde. Tentativo refresh sessione..."
    if [ -x "$REFRESH_SCRIPT" ]; then
        "$REFRESH_SCRIPT" 2>&1 >> "$LOGFILE" || true
    fi
fi

if curl -s -o /dev/null --max-time 5 "${FTP_BASE}/" ${FTP_CURL_AUTH} 2>/dev/null; then

    # --- Calcola md5 dei file locali (incrementale: skip se mtime+size invariati) ---
    LOCAL_MD5=$(mktemp)
    log "Calcolo md5 file locali (incrementale)..."
    # Carica manifest precedente in array associativi per lookup rapido
    declare -A _PREV_HASH _PREV_MTIME _PREV_SIZE
    if [ -f "$MANIFEST" ]; then
        while IFS=' ' read -r _rel _md5 _mt _sz; do
            [ -z "$_rel" ] && continue
            _PREV_HASH["$_rel"]="$_md5"
            _PREV_MTIME["$_rel"]="${_mt:-}"
            _PREV_SIZE["$_rel"]="${_sz:-}"
        done < "$MANIFEST"
    fi
    HASH_COMPUTED=0
    HASH_CACHED=0
    while IFS= read -r rel; do
        file_stat=$(stat -c '%Y %s' "${REPO}/${rel}" 2>/dev/null) || continue
        file_mtime="${file_stat%% *}"
        file_size="${file_stat##* }"
        if [ "${_PREV_MTIME[$rel]:-}" = "$file_mtime" ] \
            && [ "${_PREV_SIZE[$rel]:-}" = "$file_size" ] \
            && [ -n "${_PREV_HASH[$rel]:-}" ]; then
            md5="${_PREV_HASH[$rel]}"
            HASH_CACHED=$((HASH_CACHED + 1))
        else
            md5=$(sudo md5sum "${REPO}/${rel}" | awk '{print $1}')
            HASH_COMPUTED=$((HASH_COMPUTED + 1))
        fi
        echo "${rel} ${md5} ${file_mtime} ${file_size}"
    done < <(find "${REPO}" -type f ! -name ".proton-manifest" ! -name ".proton-stuck" -printf '%P\n' | sort) > "$LOCAL_MD5"
    unset _PREV_HASH _PREV_MTIME _PREV_SIZE
    LOCAL_COUNT=$(wc -l < "$LOCAL_MD5")
    log "md5: ${LOCAL_COUNT} file (${HASH_COMPUTED} calcolati, ${HASH_CACHED} da cache mtime+size)"

    # --- Carica manifest precedente ---
    PREV_MANIFEST=$(mktemp)
    if [ -f "$MANIFEST" ]; then
        sort "$MANIFEST" > "$PREV_MANIFEST"
    else
        : > "$PREV_MANIFEST"
    fi
    PREV_COUNT=$(wc -l < "$PREV_MANIFEST")

    # --- Determina file da caricare (md5 diverso o mancante) ---
    UPLOAD_LIST=$(mktemp)
    while IFS=' ' read -r rel_path local_md5 _rest; do
        [ -z "$rel_path" ] && continue
        prev_md5=$(grep -m1 "^${rel_path} " "$PREV_MANIFEST" 2>/dev/null | awk '{print $2}' || true)
        if [ "$local_md5" != "$prev_md5" ]; then
            echo "$rel_path" >> "$UPLOAD_LIST"
        fi
    done < "$LOCAL_MD5"
    UPLOAD_COUNT=$(wc -l < "$UPLOAD_LIST")

    # --- Determina file obsoleti (nel manifest ma non più in locale) ---
    # hints.*/index.*/integrity.* cambiano numero ad ogni prune: li gestiamo
    # come orfani remoti, cosi' il set corrente locale non viene mai eliminato.
    OBSOLETE_LIST=$(mktemp)
    while IFS=' ' read -r rel_path _md5; do
        [ -z "$rel_path" ] && continue
        [[ "$rel_path" =~ ^(hints|index|integrity)\. ]] && continue
        if ! grep -q "^${rel_path} " "$LOCAL_MD5" 2>/dev/null; then
            echo "$rel_path" >> "$OBSOLETE_LIST"
        fi
    done < "$PREV_MANIFEST"
    OBSOLETE_COUNT=$(wc -l < "$OBSOLETE_LIST")

    log "Sync → Proton: locale=${LOCAL_COUNT} manifest=${PREV_COUNT} upload=${UPLOAD_COUNT} delete=${OBSOLETE_COUNT}"

    # --- Listing FTP di Proton (per riconciliazione) ---
    REMOTE_LIST=$(mktemp)
    log "Listing file su Proton..."
    ftp_list_recursive() {
        local base_url="$1" base_path="$2"
        local listing
        listing=$(curl -s --max-time 30 "${base_url}${base_path}/" ${FTP_CURL_AUTH} 2>/dev/null) || return 0
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local name perms
            name=$(echo "$line" | awk '{print $NF}')
            perms=$(echo "$line" | awk '{print $1}')
            if [[ "$perms" == d* ]]; then
                ftp_list_recursive "$base_url" "${base_path}/${name}"
            else
                echo "${base_path}/${name}"
            fi
        done <<< "$listing"
    }
    ftp_list_recursive "${FTP_BASE}" "${FTP_REMOTE_DIR}" 2>/dev/null \
        | sed "s|^${FTP_REMOTE_DIR}/||" | sort > "$REMOTE_LIST" || true
    REMOTE_COUNT=$(wc -l < "$REMOTE_LIST")
    log "File su Proton: ${REMOTE_COUNT}"

    # --- Costruisci nuovo manifest: file invariati che esistono su Proton ---
    NEW_MANIFEST=$(mktemp)
    PHANTOM_COUNT=0
    while IFS=' ' read -r rel_path local_md5; do
        [ -z "$rel_path" ] && continue
        if ! grep -q "^${rel_path}$" "$UPLOAD_LIST" 2>/dev/null; then
            # File invariato — verifica che sia davvero su Proton
            if grep -q "^${rel_path}$" "$REMOTE_LIST" 2>/dev/null; then
                echo "$rel_path $local_md5" >> "$NEW_MANIFEST"
            else
                # Fantasma: nel manifest ma sparito da Proton → forza re-upload
                echo "$rel_path" >> "$UPLOAD_LIST"
                UPLOAD_COUNT=$((UPLOAD_COUNT + 1))
                PHANTOM_COUNT=$((PHANTOM_COUNT + 1))
            fi
        fi
    done < "$LOCAL_MD5"
    [ "$PHANTOM_COUNT" -gt 0 ] && log "WARN: ${PHANTOM_COUNT} file fantasma (nel manifest ma non su Proton) — verranno ri-uploadati"

    # --- File orfani su Proton (su Proton ma non in locale, esclusi obsoleti) ---
    ORPHAN_LIST=$(mktemp)
    while IFS= read -r remote_rel; do
        [ -z "$remote_rel" ] && continue
        # Ignora file .new-* (fallback per file stuck — gestiti separatamente)
        [[ "$remote_rel" == *.new-* ]] && continue
        if ! grep -q "^${remote_rel} " "$LOCAL_MD5" 2>/dev/null; then
            # Escludi file già in lista obsoleti (evita duplicati in email)
            grep -q "^${remote_rel}$" "$OBSOLETE_LIST" 2>/dev/null && continue
            echo "$remote_rel" >> "$ORPHAN_LIST"
        fi
    done < "$REMOTE_LIST"
    ORPHAN_COUNT=$(wc -l < "$ORPHAN_LIST")
    [ "$ORPHAN_COUNT" -gt 0 ] && log "Trovati ${ORPHAN_COUNT} file orfani su Proton (non in locale) — verrà tentato DELE automatico"

    # --- Upload con verifica md5 post-download ---
    UPLOAD_OK=0
    UPLOAD_FAIL=0
    MAX_RETRIES=3
    BRIDGE_RESTART_EVERY=50   # restart bridge ogni N upload per evitare degradazione
    UPLOAD_SINCE_RESTART=0
    STUCK_FILE="${REPO}/.proton-stuck"
    RESOLVED_NEW_LIST=$(mktemp)   # .new-* obsoleti da file risolti (per email)

    log "Inizio upload: ${UPLOAD_COUNT} file da caricare/verificare..."

    while IFS= read -r rel_path; do
        [ -z "$rel_path" ] && continue
        local_file="${REPO}/${rel_path}"
        if [ ! -f "$local_file" ]; then
            log "WARN: ${rel_path} scomparso dal repo — skip upload"
            continue
        fi
        remote_url="${FTP_BASE}${FTP_REMOTE_DIR}/${rel_path}"
        local_md5=$(grep -m1 "^${rel_path} " "$LOCAL_MD5" 2>/dev/null | awk '{print $2}' || true)

        # Restart preventivo del bridge per evitare cache/memory corruption
        if [ "$UPLOAD_SINCE_RESTART" -ge "$BRIDGE_RESTART_EVERY" ]; then
            log "Restart bridge preventivo (dopo ${UPLOAD_SINCE_RESTART} upload)..."
            sudo systemctl restart proton-drive-bridge 2>/dev/null || true
            sleep 8
            if ! curl -s -o /dev/null --max-time 10 "${FTP_BASE}/" ${FTP_CURL_AUTH} 2>/dev/null; then
                log "WARN: bridge non risponde dopo restart — attendo..."
                sleep 15
            fi
            UPLOAD_SINCE_RESTART=0
        fi

        verified=false
        is_stuck=false
        [ -f "$STUCK_FILE" ] && grep -q "^${rel_path}$" "$STUCK_FILE" 2>/dev/null && is_stuck=true

        if [ "$is_stuck" = true ] && grep -q "^${rel_path}$" "$REMOTE_LIST" 2>/dev/null; then
            # --- File stuck e originale ancora presente su Proton ---
            # L'overwrite non funziona: skip retry normali, verifica .new-* esistente
            escaped_path=$(printf '%s' "$rel_path" | sed 's/[].[^$*+?{}|()\\]/\\&/g')
            latest_new=$(grep "^${escaped_path}\.new-" "$REMOTE_LIST" 2>/dev/null | sort | tail -1 || true)
            if [ -n "$latest_new" ]; then
                log "File stuck ${rel_path}: verifico ${latest_new} esistente..."
                new_url="${FTP_BASE}${FTP_REMOTE_DIR}/${latest_new}"
                verify_existing_md5=$(curl -s --limit-rate "$RATE_LIMIT" --max-time 3600 \
                    "$new_url" ${FTP_CURL_AUTH} 2>/dev/null | md5sum | awk '{print $1}') || true
                if [ "$verify_existing_md5" = "$local_md5" ]; then
                    verified=true
                    log "OK: ${rel_path} verificato via ${latest_new} (contenuto invariato)"
                else
                    log "WARN: ${latest_new} ha md5 diverso (contenuto cambiato) — serve nuovo upload"
                fi
            fi

            # Se .new-* non esiste o md5 non corrisponde → crea nuovo .new-<epoch> (3 tentativi)
            if [ "$verified" = false ]; then
                for new_attempt in $(seq 1 "$MAX_RETRIES"); do
                    fallback_suffix=".new-$(date +%s)"
                    log "Upload fallback ${rel_path}${fallback_suffix} (tentativo ${new_attempt}/${MAX_RETRIES})..."
                    sudo systemctl restart proton-drive-bridge 2>/dev/null || true
                    sleep 8
                    UPLOAD_SINCE_RESTART=0

                    curl -s --limit-rate "$RATE_LIMIT" --max-time 3600 --ftp-create-dirs \
                        -T "$local_file" "${remote_url}${fallback_suffix}" ${FTP_CURL_AUTH} 2>/dev/null || true
                    sleep 3
                    verify_new_md5=$(curl -s --limit-rate "$RATE_LIMIT" --max-time 3600 \
                        "${remote_url}${fallback_suffix}" ${FTP_CURL_AUTH} 2>/dev/null | md5sum | awk '{print $1}') || true

                    if [ "$verify_new_md5" = "$local_md5" ]; then
                        verified=true
                        log "OK: ${rel_path} salvato come ${rel_path}${fallback_suffix}"
                        break
                    fi
                    log "WARN: fallback ${fallback_suffix} fallito per ${rel_path} (tentativo ${new_attempt}/${MAX_RETRIES})"
                done
            fi
        else
            # --- File NON stuck (o stuck ma originale cancellato da Proton) ---
            # Tentativo normale: upload + verifica md5
            for attempt in $(seq 1 "$MAX_RETRIES"); do
                curl -s --limit-rate "$RATE_LIMIT" --max-time 3600 --ftp-create-dirs \
                    -T "$local_file" "$remote_url" ${FTP_CURL_AUTH} 2>/dev/null || true

                verify_md5=$(curl -s --limit-rate "$RATE_LIMIT" --max-time 3600 \
                    "$remote_url" ${FTP_CURL_AUTH} 2>/dev/null | md5sum | awk '{print $1}') || true

                if [ "$verify_md5" = "$local_md5" ]; then
                    verified=true
                    # Se era stuck e ora funziona (utente ha cancellato originale da web)
                    if [ "$is_stuck" = true ]; then
                        sed -i "\|^${rel_path}$|d" "$STUCK_FILE"
                        log "OK: ${rel_path} non più stuck (overwrite riuscito dopo cleanup web)"
                        # Raccogli .new-* obsoleti per notifica
                        escaped_path=$(printf '%s' "$rel_path" | sed 's/[].[^$*+?{}|()\\]/\\&/g')
                        grep "^${escaped_path}\.new-" "$REMOTE_LIST" 2>/dev/null >> "$RESOLVED_NEW_LIST" || true
                    fi
                    break
                fi
                log "WARN: verifica fallita per ${rel_path} (tentativo ${attempt}/${MAX_RETRIES}, local=${local_md5} remote=${verify_md5})"
                if [ "$attempt" -lt "$MAX_RETRIES" ]; then
                    sudo systemctl restart proton-drive-bridge 2>/dev/null || true
                    sleep 8
                    UPLOAD_SINCE_RESTART=0
                fi
            done

            # Fallback .new-<epoch> se tutti i retry normali sono falliti (3 tentativi)
            if [ "$verified" = false ]; then
                if [ "$is_stuck" = true ]; then
                    log "WARN: ${rel_path} era stuck, originale eliminato da Proton ma overwrite ancora fallisce!"
                fi
                for new_attempt in $(seq 1 "$MAX_RETRIES"); do
                    fallback_suffix=".new-$(date +%s)"
                    log "WARN: fallback ${fallback_suffix} per ${rel_path} (tentativo ${new_attempt}/${MAX_RETRIES})..."
                    sudo systemctl restart proton-drive-bridge 2>/dev/null || true
                    sleep 8
                    UPLOAD_SINCE_RESTART=0

                    curl -s --limit-rate "$RATE_LIMIT" --max-time 3600 --ftp-create-dirs \
                        -T "$local_file" "${remote_url}${fallback_suffix}" ${FTP_CURL_AUTH} 2>/dev/null || true
                    sleep 3
                    verify_new_md5=$(curl -s --limit-rate "$RATE_LIMIT" --max-time 3600 \
                        "${remote_url}${fallback_suffix}" ${FTP_CURL_AUTH} 2>/dev/null | md5sum | awk '{print $1}') || true

                    if [ "$verify_new_md5" = "$local_md5" ]; then
                        verified=true
                        log "OK: ${rel_path} salvato come ${rel_path}${fallback_suffix}"
                        echo "${rel_path}" >> "$STUCK_FILE"
                        if [ "$is_stuck" = true ]; then
                            log "WARN: caso anomalo — ${rel_path} era stuck, originale eliminato, ma bridge ancora non sovrascrive. Salvato come .new"
                        fi
                        break
                    fi
                    log "WARN: fallback ${fallback_suffix} fallito per ${rel_path} (tentativo ${new_attempt}/${MAX_RETRIES})"
                done
            fi
        fi

        UPLOAD_SINCE_RESTART=$((UPLOAD_SINCE_RESTART + 1))
        if [ "$verified" = true ]; then
            UPLOAD_OK=$((UPLOAD_OK + 1))
            grep -m1 "^${rel_path} " "$LOCAL_MD5" >> "$NEW_MANIFEST"
        else
            UPLOAD_FAIL=$((UPLOAD_FAIL + 1))
            log "ERRORE: ${rel_path} fallito dopo tutti i tentativi"
        fi
    done < "$UPLOAD_LIST"

    if [ "$UPLOAD_COUNT" -gt 0 ]; then
        log "Upload completato: ${UPLOAD_OK} OK, ${UPLOAD_FAIL} FAIL su ${UPLOAD_COUNT}"
    else
        log "Nessun file da caricare — Proton allineato"
    fi

    # --- Salva manifest atomicamente ---
    sort "$NEW_MANIFEST" > "${MANIFEST}.tmp"
    mv -f "${MANIFEST}.tmp" "$MANIFEST"

    if [ "$UPLOAD_FAIL" -gt 0 ]; then
        log "WARN: ${UPLOAD_FAIL} file non verificati — verranno ritentati al prossimo run"
    fi

    # --- Step 5: Auto-delete file da Proton Drive via FTP DELE ---------------
    # Elimina automaticamente: obsoleti, orfani (inclusi hints/index/integrity
    # vecchi nella root del repo), .new-* risolti, originali di file stuck.
    # Solo i file che falliscono il DELE vengono
    # segnalati via email per intervento manuale.

    proton_ftp_delete() {
        local rel_path="$1"
        curl -s --max-time 30 --quote "DELE ${FTP_REMOTE_DIR}/${rel_path}" \
            "${FTP_BASE}/" ${FTP_CURL_AUTH} >/dev/null 2>&1
    }

    DELETE_OK=0
    DELETE_FAIL=0
    DELETE_FAIL_LIST=$(mktemp)

    # 5a. File obsoleti (nel vecchio manifest ma non più in locale — prunati da Borg)
    if [ "$OBSOLETE_COUNT" -gt 0 ]; then
        log "Auto-delete: ${OBSOLETE_COUNT} file obsoleti..."
        while IFS= read -r obs_path; do
            [ -z "$obs_path" ] && continue
            if proton_ftp_delete "$obs_path"; then
                DELETE_OK=$((DELETE_OK + 1))
                log "  DELE OK: ${obs_path}"
            else
                DELETE_FAIL=$((DELETE_FAIL + 1))
                echo "obsoleto: ${obs_path}" >> "$DELETE_FAIL_LIST"
                log "  DELE FAIL: ${obs_path}"
            fi
        done < "$OBSOLETE_LIST"
    fi

    # 5b. File orfani (su Proton ma non in locale/manifest)
    if [ "$ORPHAN_COUNT" -gt 0 ]; then
        log "Auto-delete: ${ORPHAN_COUNT} file orfani..."
        while IFS= read -r orph_path; do
            [ -z "$orph_path" ] && continue
            if proton_ftp_delete "$orph_path"; then
                DELETE_OK=$((DELETE_OK + 1))
                log "  DELE OK: ${orph_path}"
            else
                DELETE_FAIL=$((DELETE_FAIL + 1))
                echo "orfano: ${orph_path}" >> "$DELETE_FAIL_LIST"
                log "  DELE FAIL: ${orph_path}"
            fi
        done < "$ORPHAN_LIST"
    fi

    # 5c. File .new-* risolti (file stuck ora uploadati correttamente con nome originale)
    if [ -s "$RESOLVED_NEW_LIST" ]; then
        sort -u -o "$RESOLVED_NEW_LIST" "$RESOLVED_NEW_LIST"
        RESOLVED_COUNT=$(wc -l < "$RESOLVED_NEW_LIST")
        log "Auto-delete: ${RESOLVED_COUNT} file .new-* risolti..."
        while IFS= read -r resolved_path; do
            [ -z "$resolved_path" ] && continue
            if proton_ftp_delete "$resolved_path"; then
                DELETE_OK=$((DELETE_OK + 1))
                log "  DELE OK .new-*: ${resolved_path}"
            else
                DELETE_FAIL=$((DELETE_FAIL + 1))
                echo ".new-* risolto: ${resolved_path}" >> "$DELETE_FAIL_LIST"
                log "  DELE FAIL .new-*: ${resolved_path}"
            fi
        done < "$RESOLVED_NEW_LIST"
    fi

    # 5d. Originali di file stuck (DELE originale → prossimo run ricarica pulito)
    STUCK_MANUAL_COUNT=0
    if [ -f "$STUCK_FILE" ]; then
        # Pulisci stuck: rimuovi file che non esistono più in locale
        STUCK_CLEAN=$(mktemp)
        while IFS= read -r sp; do
            [ -z "$sp" ] && continue
            grep -q "^${sp} " "$LOCAL_MD5" 2>/dev/null && echo "$sp"
        done < "$STUCK_FILE" > "$STUCK_CLEAN"
        mv -f "$STUCK_CLEAN" "$STUCK_FILE"
        sort -u -o "$STUCK_FILE" "$STUCK_FILE"
        STUCK_COUNT=$(wc -l < "$STUCK_FILE")
    else
        STUCK_COUNT=0
    fi
    if [ "$STUCK_COUNT" -gt 0 ]; then
        log "Auto-delete: ${STUCK_COUNT} originali stuck (mantiene .new-* verificati fino al re-upload)..."
        while IFS= read -r stuck_path; do
            [ -z "$stuck_path" ] && continue
            # Elimina solo l'originale stuck. I .new-* sono copie verificate e
            # restano su Proton fino al prossimo run, che ricarica l'originale
            # e poi li elimina tramite RESOLVED_NEW_LIST.
            if proton_ftp_delete "$stuck_path"; then
                DELETE_OK=$((DELETE_OK + 1))
                log "  DELE OK stuck orig: ${stuck_path} (re-upload al prossimo run; .new-* tenuti)"
            else
                DELETE_FAIL=$((DELETE_FAIL + 1))
                STUCK_MANUAL_COUNT=$((STUCK_MANUAL_COUNT + 1))
                echo "stuck orig: ${stuck_path}" >> "$DELETE_FAIL_LIST"
                log "  DELE FAIL stuck orig: ${stuck_path}"
            fi
        done < "$STUCK_FILE"
    fi

    TOTAL_DELETE=$((DELETE_OK + DELETE_FAIL))
    if [ "$TOTAL_DELETE" -gt 0 ]; then
        log "Auto-delete completato: ${DELETE_OK} OK, ${DELETE_FAIL} FAIL su ${TOTAL_DELETE}"
    fi

    # --- Email solo per file che non si è riusciti a eliminare ----------------
    if [ "$DELETE_FAIL" -gt 0 ] || [ "$STUCK_MANUAL_COUNT" -gt 0 ]; then
        email_body="Backup offsite di $(hostname) completato il $(date '+%d/%m/%Y %H:%M')."$'\n'
        email_body+="Upload: ${UPLOAD_OK} OK, ${UPLOAD_FAIL} FAIL su ${UPLOAD_COUNT} | Manifest: $(wc -l < "$MANIFEST") file"$'\n'
        email_body+="Auto-delete: ${DELETE_OK} OK, ${DELETE_FAIL} FAIL"$'\n'
        email_subject_parts=""

        if [ "$DELETE_FAIL" -gt 0 ]; then
            email_body+=$'\n'"═══ FILE NON ELIMINABILI ═══"$'\n'
            email_body+="I seguenti file non sono stati eliminati automaticamente."$'\n'
            email_body+="Eliminare manualmente da https://drive.proton.me/backup/tidepool/:"$'\n'$'\n'
            while IFS= read -r fail_line; do
                email_body+="  ${fail_line}"$'\n'
            done < "$DELETE_FAIL_LIST"
            email_subject_parts="${DELETE_FAIL} non eliminati"
        fi

        if [ "$STUCK_MANUAL_COUNT" -gt 0 ]; then
            email_body+=$'\n'"═══ FILE ANCORA STUCK ═══"$'\n'
            email_body+="Questi file non sono stati eliminati (DELE fallito)."$'\n'
            email_body+="I dati sono salvati come .new-* — eliminare gli originali manualmente:"$'\n'$'\n'
            while IFS= read -r stuck_path; do
                grep -Fxq "stuck orig: ${stuck_path}" "$DELETE_FAIL_LIST" 2>/dev/null && email_body+="  ${stuck_path}"$'\n'
            done < "$STUCK_FILE"
            email_subject_parts="${email_subject_parts:+${email_subject_parts}, }${STUCK_MANUAL_COUNT} stuck"
        fi

        send_backup_email "Azione richiesta: ${email_subject_parts} su Proton Drive" "$email_body" || true
    fi

    rm -f "$DELETE_FAIL_LIST"

    rm -f "$LOCAL_MD5" "$PREV_MANIFEST" "$UPLOAD_LIST" "$OBSOLETE_LIST" "$NEW_MANIFEST" "$REMOTE_LIST" "$ORPHAN_LIST" "$RESOLVED_NEW_LIST"
else
    log "WARN: proton-drive-bridge non raggiungibile su ${FTP_HOST}:${FTP_PORT} anche dopo refresh."
fi

# --- Fine --------------------------------------------------------------------

REPO_SIZE=$(du -sh "$REPO" | cut -f1)
log "=== BACKUP OFFSITE DONE === (repo: ${REPO_SIZE})"
