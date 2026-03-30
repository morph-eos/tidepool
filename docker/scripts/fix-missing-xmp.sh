#!/bin/sh

# ============================================================================
# SCRIPT PER CREAZIONE XMP MANCANTI - iCloudPD Fix
# ============================================================================
#
# Questo script risolve il problema dei crash di iCloudPD quando i metadata
# di iCloud sono corrotti. Crea file XMP "dummy" per le immagini già 
# scaricate che non hanno il loro file XMP corrispondente.
#
# Quando iCloudPD trova un file XMP esistente, salta il download e continua.
# Questo permette di evitare i crash sui file con metadata corrotti.
#
# ============================================================================

ICLOUD_DIR="/app/photos"
LOG_FILE="/app/photos/fix-xmp.log"

# Funzione di logging
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Funzione per creare XMP dummy
create_dummy_xmp() {
    local file="$1"
    local xmp_file="${file}.xmp"
    
    # Estrae i metadati di base dal file usando exiftool se disponibile
    local width height
    if command -v exiftool >/dev/null 2>&1; then
        width=$(exiftool -s -s -s -ImageWidth "$file" 2>/dev/null || echo "")
        height=$(exiftool -s -s -s -ImageHeight "$file" 2>/dev/null || echo "")
    fi
    
    # Se non abbiamo exiftool o i dati, usiamo valori di default
    width=${width:-"1920"}
    height=${height:-"1080"}
    
    # Crea un XMP minimale senza description e date
    cat > "$xmp_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:tiff="http://ns.adobe.com/tiff/1.0/">
   <tiff:ImageWidth>${width}</tiff:ImageWidth>
   <tiff:ImageLength>${height}</tiff:ImageLength>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
EOF

    log "Created dummy XMP for: $(basename "$file")"
}

# Funzione principale
main() {
    log "=== Starting XMP fix process ==="
    
    if [ ! -d "$ICLOUD_DIR" ]; then
        log "ERROR: iCloud directory not found: $ICLOUD_DIR"
        exit 1
    fi
    
    local count=0
    
    # Cerca tutti i file immagine e video che non hanno un XMP corrispondente
    # Supporta: jpg, jpeg, png, tiff, tif, heic, mov, mp4, m4v, dng, raw
    find "$ICLOUD_DIR" -type f \( \
        -iname "*.jpg" -o \
        -iname "*.jpeg" -o \
        -iname "*.png" -o \
        -iname "*.tiff" -o \
        -iname "*.tif" -o \
        -iname "*.heic" -o \
        -iname "*.mov" -o \
        -iname "*.mp4" -o \
        -iname "*.m4v" -o \
        -iname "*.dng" -o \
        -iname "*.raw" \
    \) | while read -r file; do
        # Controlla se esiste già il file XMP
        if [ ! -f "${file}.xmp" ]; then
            log "Missing XMP for: $(basename "$file")"
            create_dummy_xmp "$file"
        fi
    done

    log "=== XMP fix process completed ==="
}

# Esegui lo script
main "$@"
