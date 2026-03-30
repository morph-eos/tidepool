#!/bin/sh

# ============================================================================
# SCRIPT PER REVERTARE LE MODIFICHE XMP - iCloudPD Fix Revert
# ============================================================================
#
# Questo script rimuove tutti i file XMP creati dal fix-missing-xmp.sh
# leggendo il log file e eliminando solo quelli creati dallo script.
#
# ============================================================================

ICLOUD_DIR="/app/photos"
LOG_FILE="/app/photos/fix-xmp.log"
REVERT_LOG_FILE="/app/photos/revert-xmp.log"

# Funzione di logging
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$REVERT_LOG_FILE"
}

# Funzione principale
main() {
    log "=== Starting revert-xmp-fix script ==="
    log "Reading log file: $LOG_FILE"
    
    if [ ! -f "$LOG_FILE" ]; then
        log "ERROR: Log file $LOG_FILE does not exist"
        exit 1
    fi
    
    local count=0
    local removed=0
    
    # Legge il log file e cerca le righe con "Created dummy XMP for:"
    grep "Created dummy XMP for:" "$LOG_FILE" | while read -r line; do
        # Estrae il nome del file dalla riga del log
        filename=$(echo "$line" | sed 's/.*Created dummy XMP for: //')
        
        # Cerca il file XMP in tutte le sottodirectory
        xmp_file=$(find /app/photos -name "${filename}.xmp" 2>/dev/null | head -1)
        
        if [ -n "$xmp_file" ] && [ -f "$xmp_file" ]; then
            log "Removing: $xmp_file"
            rm -f "$xmp_file"
            if [ $? -eq 0 ]; then
                removed=$((removed + 1))
                log "Successfully removed: $xmp_file"
            else
                log "ERROR: Failed to remove: $xmp_file"
            fi
        else
            log "File not found (already removed?): ${filename}.xmp"
        fi
        
        count=$((count + 1))
    done
    
    log "=== Revert completed ==="
    log "Total XMP entries found in log: $count"
    log "Files actually removed: $removed"
    
    # Opzionalmente rimuove anche il log originale
    read -p "Remove original fix-xmp.log? (y/N): " response
    case "$response" in
        [yY]|[yY][eE][sS])
            rm -f "$LOG_FILE"
            log "Removed original log file: $LOG_FILE"
            ;;
        *)
            log "Keeping original log file: $LOG_FILE"
            ;;
    esac
}

# Esegui se chiamato direttamente
if [ "${0##*/}" = "revert-xmp-fix.sh" ]; then
    main "$@"
fi
