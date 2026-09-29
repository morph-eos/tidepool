#!/bin/sh

# ============================================================================
# SCRIPT TO CREATE MISSING XMP FILES - iCloudPD Fix
# ============================================================================
#
# This script solves the problem of iCloudPD crashes when the iCloud metadata
# is corrupted. It creates "dummy" XMP files for the images already
# downloaded that do not have their corresponding XMP file.
#
# When iCloudPD finds an existing XMP file, it skips the download and continues.
# This avoids crashes on files with corrupted metadata.
#
# ============================================================================

ICLOUD_DIR="/app/photos"
LOG_FILE="/app/photos/fix-xmp.log"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to create a dummy XMP
create_dummy_xmp() {
    local file="$1"
    local xmp_file="${file}.xmp"
    
    # Extract basic metadata from the file using exiftool if available
    local width height
    if command -v exiftool >/dev/null 2>&1; then
        width=$(exiftool -s -s -s -ImageWidth "$file" 2>/dev/null || echo "")
        height=$(exiftool -s -s -s -ImageHeight "$file" 2>/dev/null || echo "")
    fi
    
    # If we do not have exiftool or the data, use default values
    width=${width:-"1920"}
    height=${height:-"1080"}
    
    # Create a minimal XMP without description and date
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

# Main function
main() {
    log "=== Starting XMP fix process ==="
    
    if [ ! -d "$ICLOUD_DIR" ]; then
        log "ERROR: iCloud directory not found: $ICLOUD_DIR"
        exit 1
    fi
    
    local count=0
    
    # Find all image and video files that do not have a corresponding XMP
    # Supports: jpg, jpeg, png, tiff, tif, heic, mov, mp4, m4v, dng, raw
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
        # Check whether the XMP file already exists
        if [ ! -f "${file}.xmp" ]; then
            log "Missing XMP for: $(basename "$file")"
            create_dummy_xmp "$file"
        fi
    done

    log "=== XMP fix process completed ==="
}

# Run the script
main "$@"
