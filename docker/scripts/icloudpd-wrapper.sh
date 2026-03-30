#!/bin/sh

# ============================================================================
# ICLOUDPD WRAPPER SCRIPT - Gestione automatica crash XMP
# ============================================================================
#
# Questo script wrapper:
# 1. Esegue il fix degli XMP mancanti all'avvio
# 2. Monitora iCloudPD per i crash
# 3. Quando rileva un crash, esegue il fix XMP e riavvia
# 4. Mantiene il normale comportamento di iCloudPD
#
# ============================================================================

ICLOUD_DIR="/app/photos"
LOG_FILE="/app/photos/icloudpd-wrapper.log"
CRASH_LOG="/app/photos/crash-recovery.log"
DOWNLOAD_LOG="/app/photos/latest-downloads.log"

# Comando opzionale per mettere on hold il container all'avvio per autenticazione
# sleep 3600

# Funzione di logging
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Funzione per eseguire il fix XMP
run_xmp_fix() {
    log "Running XMP fix for missing sidecars..."
    if [ -x "/app/scripts/fix-missing-xmp.sh" ]; then
        sh /app/scripts/fix-missing-xmp.sh
        log "XMP fix completed"
    else
        log "WARNING: fix-missing-xmp.sh not found or not executable"
    fi
}

# Funzione per eseguire l'update XMP
run_xmp_update() {
    log "Updating XMP date/time for downloaded files listed in latest-downloads.log..."
    if [ ! -x "/app/scripts/update-xmp-datetime.sh" ]; then
        log "ERROR: update-xmp-datetime.sh not found or not executable"
        return
    fi

    if [ ! -f "$DOWNLOAD_LOG" ]; then
        log "No $DOWNLOAD_LOG found; nothing to update."
        return
    fi

    # Estrai i file scaricati dal log dedicato; supporta sia righe "Downloaded <path>" che righe contenenti solo il path
    files=$(sed -E 's/^.*Downloaded[[:space:]]+//; s/[[:space:]]+$//' "$DOWNLOAD_LOG" \
        | awk 'BEGIN{RS="\n"} /^\// {print}' \
        | sort -u)

    if [ -z "$files" ]; then
        log "No downloaded files found in $DOWNLOAD_LOG; nothing to update."
        return
    fi

    total=$(printf '%s\n' "$files" | wc -l | awk '{print $1}')
    log "Found $total downloaded file(s) to update."

    pending_tmp=$(mktemp /tmp/latest-downloads.pending.XXXXXX)
    success_all=true
    printf '%s\n' "$files" | while IFS= read -r f; do
        if [ -f "$f" ]; then
            if /app/scripts/update-xmp-datetime.sh "$f"; then
                :
            else
                log "WARNING: Failed XMP update for $f"
                printf '%s\n' "$f" >> "$pending_tmp"
                success_all=false
            fi
        else
            log "WARNING: File not found on disk: $f"
            printf '%s\n' "$f" >> "$pending_tmp"
            success_all=false
        fi
    done

    # Se tutti aggiornati, cancella il log; altrimenti mantieni solo i rimanenti
    if [ "$success_all" = true ] && [ ! -s "$pending_tmp" ]; then
        log "XMP updates completed for all downloaded files. Cleaning up $DOWNLOAD_LOG."
        rm -f "$DOWNLOAD_LOG" || log "WARNING: could not remove $DOWNLOAD_LOG"
    else
        # Sostituisci il log con la lista dei pendenti, deduplicata (come plain path, gestiti al prossimo run)
        sort -u "$pending_tmp" > "$DOWNLOAD_LOG"
        left=$(wc -l < "$DOWNLOAD_LOG" | tr -d ' ')
        log "Some files could not be updated. Keeping $left pending item(s) in $DOWNLOAD_LOG for next run."
    fi
    rm -f "$pending_tmp" 2>/dev/null || true
}

# Funzione per eseguire iCloudPD
run_icloudpd() {
    log "Starting iCloudPD with parameters:"
    log "  Username: ${ICLOUD_USERNAME}"
    log "  Directory: ${ICLOUD_DIR}"
    log "  Sync interval: ${ICLOUD_SYNC_INTERVAL:-3600}s"
    
    # Esegue iCloudPD con i parametri corretti per la nuova versione
    # Doppio logging: stdout del wrapper (per chi fa docker logs) + file dedicato latest-downloads.log
    PIPE="/tmp/icloudpd_stream.$$.pipe"
    rm -f "$PIPE" 2>/dev/null || true
    mkfifo "$PIPE"
    # tee in background: scrive sia su stdout che su DOWNLOAD_LOG
    tee -a "$DOWNLOAD_LOG" < "$PIPE" &
    TEE_PID=$!

    # /app/icloudpd icloudpd --username "${ICLOUD_USERNAME}" --directory "${ICLOUD_DIR}" \
    #     --cookie-directory "${ICLOUD_DIR}" \
    #     --folder-structure "{:%Y/%m}" \
    #     --set-exif-datetime \
    #     --xmp-sidecar \
    #     --size adjusted \
    #     --align-raw alternative \
    #     --threads-num 1 \
    #     --no-progress-bar \
    #     --skip-created-after 30d \
    #     --keep-icloud-recent-days 30 \
    #     --smtp-username "${SMTP_USERNAME}" \
    #     --smtp-password "${SMTP_PASSWORD}" \
    #     > "$PIPE" 2>&1
        /app/icloudpd --username "${ICLOUD_USERNAME}" --directory "${ICLOUD_DIR}" \
        --cookie-directory "${ICLOUD_DIR}" \
        --folder-structure "{:%Y/%m}" \
        --set-exif-datetime \
        --xmp-sidecar \
        --size adjusted \
        --align-raw alternative \
        --threads-num 1 \
        --no-progress-bar \
        --keep-icloud-recent-days 0 \
        --smtp-username "${SMTP_USERNAME}" \
        --smtp-password "${SMTP_PASSWORD}" \
        > "$PIPE" 2>&1
    cmd_ec=$?
    # Chiudi tee e pulisci
    wait $TEE_PID 2>/dev/null || true
    rm -f "$PIPE" 2>/dev/null || true
    return $cmd_ec
}

# Controllo exiftool (installa se manca)
ensure_exiftool() {
    if ! command -v exiftool >/dev/null 2>&1; then
        log "exiftool not found, installing..."
        if command -v apk >/dev/null 2>&1; then
            apk add --no-cache exiftool || {
                log "ERROR: Failed to install exiftool via apk"
                exit 1
            }
        elif command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y exiftool || {
                log "ERROR: Failed to install exiftool via apt-get"
                exit 1
            }
        else
            log "ERROR: Package manager not found (apk/apt-get)"
            exit 1
        fi
        log "exiftool installed successfully"
    else
        log "exiftool already installed"
    fi
}

# Funzione principale
main() {
    log "=== iCloudPD Wrapper Script Started ==="
    log "Version: 1.0"
    log "Target directory: ${ICLOUD_DIR}"
    
    # Verifica che la directory esista
    if [ ! -d "${ICLOUD_DIR}" ]; then
        log "ERROR: Directory ${ICLOUD_DIR} does not exist"
        exit 1
    fi
    
    # Esegue il fix XMP iniziale per tutti i file esistenti
    log "Performing initial XMP fix for existing files..."
    run_xmp_fix

    log "Checking exiftool..."
    ensure_exiftool
    
    # Loop principale con gestione crash
    while true; do
        log "=== Starting iCloudPD synchronization ==="
        
        # Esegue iCloudPD
        run_icloudpd
        exit_code=$?
        
        # Log del risultato
        if [ $exit_code -eq 0 ]; then
            log "iCloudPD completed successfully"

            # Controlla se gli xmp sono aggiornati
            log "Running XMP date/time update after successful sync..."
            run_xmp_update

            log "Waiting for next sync interval..."
            sleep ${ICLOUD_SYNC_INTERVAL:-3600}
        else
            log "iCloudPD exited with code: $exit_code"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Crash detected (exit code: $exit_code)" >> "$CRASH_LOG"
            
            # Se il codice di uscita indica un crash, esegue il fix
            if [ $exit_code -ne 0 ]; then
                log "Crash detected! Running XMP fix before retry..."
                run_xmp_fix
                
                # Attende un po' prima di riprovare
                log "Waiting 5 seconds before retry..."
                sleep 5
            else
                log "Weird state detected, exiting loop."
                break
            fi
        fi
    done
    
    log "=== iCloudPD Wrapper Script Finished ==="
}

# Trap per gestire i segnali
trap 'log "Received termination signal, shutting down..."; exit 0' TERM INT

# Esegue se chiamato direttamente
if [ "${0##*/}" = "icloudpd-wrapper.sh" ]; then
    main "$@"
fi
