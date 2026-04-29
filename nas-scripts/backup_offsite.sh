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
    send_backup_email "ERRORE backup offsite" \
        "Il backup offsite di $(hostname) è FALLITO il $(date '+%d/%m/%Y %H:%M')."$'\n'$'\n'"Errore: $*"$'\n'$'\n'"Controlla il log: /var/log/backup-offsite.log" 2>/dev/null || true
    cleanup
    exit 1
}

# Invia email di notifica (usa SMTP da .env, stesse variabili di smartcheck)
send_backup_email() {
    local subject="$1" body="$2"
    local env_file="/mnt/nas2/docker/.env"
    [ -f "$env_file" ] || { log "WARN: .env non trovato, email non inviata"; return 1; }

    local smtp_host smtp_port smtp_user smtp_pass smtp_from smtp_to
    smtp_host=$(grep '^SMART_SMTP_HOST=' "$env_file" | cut -d= -f2)
    smtp_port=$(grep '^SMART_SMTP_PORT=' "$env_file" | cut -d= -f2)
    smtp_user=$(grep '^SMART_SMTP_USERNAME=' "$env_file" | cut -d= -f2)
    smtp_pass=$(grep '^SMART_SMTP_PASSWORD=' "$env_file" | cut -d= -f2)
    smtp_from=$(grep '^SMART_SMTP_FROM=' "$env_file" | cut -d= -f2)
    smtp_to=$(grep '^SMART_ALERT_EMAIL=' "$env_file" | cut -d= -f2)

    if [ -z "$smtp_host" ] || [ -z "$smtp_to" ]; then
        log "WARN: variabili SMTP incomplete, email non inviata"
        return 1
    fi

    curl -s --max-time 30 --url "smtps://${smtp_host}:${smtp_port}" \
        --ssl-reqd \
        --mail-from "$smtp_from" \
        --mail-rcpt "$smtp_to" \
        --user "${smtp_user}:${smtp_pass}" \
        -T - <<MAILEOF
From: ${smtp_from}
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
    done < <(find "${REPO}" -type f ! -name ".proton-manifest" ! -name ".proton-stuck" ! -name "nonce" -printf '%P\n' | sort) > "$LOCAL_MD5"
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
    # hints.*/index.*/integrity.* cambiano numero ad ogni prune — ignorati (gestiti a parte)
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
    BORG_META_SIZE_BYTES=0
    BORG_META_COUNT=0
    while IFS= read -r remote_rel; do
        [ -z "$remote_rel" ] && continue
        # Ignora file .new-* (fallback per file stuck — gestiti separatamente)
        [[ "$remote_rel" == *.new-* ]] && continue
        # hints/index/integrity vecchi: conta dimensione ma non listare come orfani
        if [[ "$remote_rel" =~ ^(hints|index|integrity)\. ]]; then
            if ! grep -q "^${remote_rel} " "$LOCAL_MD5" 2>/dev/null; then
                # Stima dimensione: index ~5MB, hints ~2KB, integrity ~200B
                case "$remote_rel" in
                    index.*) BORG_META_SIZE_BYTES=$((BORG_META_SIZE_BYTES + 5242880)) ;;
                    hints.*) BORG_META_SIZE_BYTES=$((BORG_META_SIZE_BYTES + 2048)) ;;
                    integrity.*) BORG_META_SIZE_BYTES=$((BORG_META_SIZE_BYTES + 256)) ;;
                esac
                BORG_META_COUNT=$((BORG_META_COUNT + 1))
            fi
            continue
        fi
        if ! grep -q "^${remote_rel} " "$LOCAL_MD5" 2>/dev/null; then
            # Escludi file già in lista obsoleti (evita duplicati in email)
            grep -q "^${remote_rel}$" "$OBSOLETE_LIST" 2>/dev/null && continue
            echo "$remote_rel" >> "$ORPHAN_LIST"
        fi
    done < "$REMOTE_LIST"
    ORPHAN_COUNT=$(wc -l < "$ORPHAN_LIST")
    [ "$ORPHAN_COUNT" -gt 0 ] && log "Trovati ${ORPHAN_COUNT} file orfani su Proton (non in locale) — da eliminare manualmente"
    # Alert se le vecchie versioni hints/index/integrity superano 10GB
    BORG_META_SIZE_GB=$((BORG_META_SIZE_BYTES / 1073741824))
    if [ "$BORG_META_COUNT" -gt 0 ]; then
        log "Info: ${BORG_META_COUNT} file Borg metadata vecchi su Proton (~${BORG_META_SIZE_GB}GB stimati)"
    fi
    if [ "$BORG_META_SIZE_BYTES" -gt 10737418240 ]; then
        send_backup_email "Pulizia Borg metadata: ~${BORG_META_SIZE_GB}GB su Proton Drive" \
            "Su Proton Drive ci sono ${BORG_META_COUNT} vecchie versioni di hints/index/integrity"$'\n'"per un totale stimato di ~${BORG_META_SIZE_GB}GB."$'\n'$'\n'"Eliminare le versioni vecchie da https://drive.proton.me"$'\n'"nella cartella backup/tidepool/ (tenere solo quelli con il numero piu' alto)." || true
    fi

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

    # --- DELE non funziona sul bridge (sempre 451) — logga e basta ---
    if [ "$OBSOLETE_COUNT" -gt 0 ]; then
        log "WARN: ${OBSOLETE_COUNT} file obsoleti su Proton (DELE non supportata dal bridge)"
    fi
    if [ "$ORPHAN_COUNT" -gt 0 ]; then
        log "WARN: ${ORPHAN_COUNT} file orfani su Proton (DELE non supportata dal bridge)"
    fi

    # --- Salva manifest atomicamente ---
    sort "$NEW_MANIFEST" > "${MANIFEST}.tmp"
    mv -f "${MANIFEST}.tmp" "$MANIFEST"

    if [ "$UPLOAD_FAIL" -gt 0 ]; then
        log "WARN: ${UPLOAD_FAIL} file non verificati — verranno ritentati al prossimo run"
    fi

    # --- Report + email file stuck (overwrite bloccato, salvati come .new-*) ---
    # Pulisci .proton-stuck: rimuovi file che non esistono più in locale (prunati da Borg)
    if [ -f "$STUCK_FILE" ]; then
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

    # Conta sezioni da eliminare manualmente
    MANUAL_DELETE_NEEDED=false
    email_body="Backup offsite di $(hostname) completato il $(date '+%d/%m/%Y %H:%M')."$'\n'
    email_body+="Upload: ${UPLOAD_OK} OK, ${UPLOAD_FAIL} FAIL su ${UPLOAD_COUNT} | Manifest: $(wc -l < "$MANIFEST") file"$'\n'
    email_subject_parts=""

    # Sezione 1: file stuck (overwrite bloccato)
    if [ "$STUCK_COUNT" -gt 0 ]; then
        MANUAL_DELETE_NEEDED=true
        log "WARN: ${STUCK_COUNT} file con overwrite bloccato."
        email_body+=$'\n'"═══ FILE BLOCCATI (overwrite non funziona) ═══"$'\n'
        email_body+="Il bridge FTP non riesce a sovrascrivere questi file (bug noto)."$'\n'
        email_body+="I dati sono stati salvati con un nome alternativo (.new-*) e verificati."$'\n'
        email_body+="Eliminare i file ORIGINALI (non i .new-*) da https://drive.proton.me"$'\n'
        email_body+="nella cartella backup/tidepool/:"$'\n'$'\n'
        while IFS= read -r stuck_path; do
            log "  STUCK: ${FTP_REMOTE_DIR}/${stuck_path}"
            email_body+="  ${stuck_path}"$'\n'
        done < "$STUCK_FILE"
        email_subject_parts="${STUCK_COUNT} bloccati"
    fi

    # Sezione 2: file obsoleti (nel vecchio manifest ma non piu' in locale)
    if [ "$OBSOLETE_COUNT" -gt 0 ]; then
        MANUAL_DELETE_NEEDED=true
        email_body+=$'\n'"═══ FILE OBSOLETI (non piu' nel backup) ═══"$'\n'
        email_body+="Questi file non sono piu' nel backup locale ma restano su Proton Drive."$'\n'
        email_body+="Eliminare da https://drive.proton.me nella cartella backup/tidepool/:"$'\n'$'\n'
        while IFS= read -r obs_path; do
            [ -z "$obs_path" ] && continue
            email_body+="  ${obs_path}"$'\n'
        done < "$OBSOLETE_LIST"
        email_subject_parts="${email_subject_parts:+${email_subject_parts}, }${OBSOLETE_COUNT} obsoleti"
    fi

    # Sezione 3: file orfani (su Proton ma mai nel manifest)
    if [ "$ORPHAN_COUNT" -gt 0 ]; then
        MANUAL_DELETE_NEEDED=true
        email_body+=$'\n'"═══ FILE ORFANI (su Proton ma non in locale) ═══"$'\n'
        email_body+="Questi file esistono su Proton Drive ma non nel backup locale."$'\n'
        email_body+="Eliminare da https://drive.proton.me nella cartella backup/tidepool/:"$'\n'$'\n'
        while IFS= read -r orph_path; do
            [ -z "$orph_path" ] && continue
            email_body+="  ${orph_path}"$'\n'
        done < "$ORPHAN_LIST"
        email_subject_parts="${email_subject_parts:+${email_subject_parts}, }${ORPHAN_COUNT} orfani"
    fi

    # Invia email unificata se serve azione manuale
    if [ "$MANUAL_DELETE_NEEDED" = true ]; then
        send_backup_email "Azione richiesta: ${email_subject_parts} su Proton Drive" "$email_body" || true
    fi

    # --- Email file .new-* obsoleti (file risolti dopo cleanup web) ---
    if [ -s "$RESOLVED_NEW_LIST" ]; then
        sort -u -o "$RESOLVED_NEW_LIST" "$RESOLVED_NEW_LIST"
        RESOLVED_COUNT=$(wc -l < "$RESOLVED_NEW_LIST")
        log "INFO: ${RESOLVED_COUNT} file .new-* ora obsoleti (originali risolti)"
        obsolete_list=""
        while IFS= read -r obsolete_path; do
            log "  OBSOLETO: ${FTP_REMOTE_DIR}/${obsolete_path}"
            obsolete_list="${obsolete_list}  ${obsolete_path}"$'\n'
        done < "$RESOLVED_NEW_LIST"

        email_body="Buone notizie! ${RESOLVED_COUNT} file precedentemente bloccati sono ora stati caricati"$'\n'
        email_body+="correttamente con il nome originale su Proton Drive."$'\n'$'\n'
        email_body+="I seguenti file .new-* sono ora OBSOLETI e possono essere eliminati"$'\n'
        email_body+="da https://drive.proton.me nella cartella backup/tidepool/:"$'\n'$'\n'
        email_body+="${obsolete_list}"
        send_backup_email "Pulizia: ${RESOLVED_COUNT} file .new-* obsoleti su Proton Drive" "$email_body" || true
    fi

    rm -f "$LOCAL_MD5" "$PREV_MANIFEST" "$UPLOAD_LIST" "$OBSOLETE_LIST" "$NEW_MANIFEST" "$REMOTE_LIST" "$ORPHAN_LIST" "$RESOLVED_NEW_LIST"
else
    log "WARN: proton-drive-bridge non raggiungibile su ${FTP_HOST}:${FTP_PORT} anche dopo refresh."
fi

# --- Fine --------------------------------------------------------------------

REPO_SIZE=$(du -sh "$REPO" | cut -f1)
log "=== BACKUP OFFSITE DONE === (repo: ${REPO_SIZE})"
