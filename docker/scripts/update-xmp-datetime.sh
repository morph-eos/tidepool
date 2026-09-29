#!/bin/sh

# Strict mode compatible with sh (no pipefail)
set -eu

usage() {
    echo "Uso: $0 DIR|FILE"
    exit 2
}

[ $# -eq 1 ] || usage
INPUT=$1
if [ -d "$INPUT" ]; then
    INPUT_TYPE=dir
elif [ -f "$INPUT" ]; then
    INPUT_TYPE=file
else
    echo "Percorso non valido: $INPUT" >&2
    exit 1
fi

# Fallback for the log function if not defined elsewhere (sh-compat)
if ! command -v log >/dev/null 2>&1; then
    log() { echo "$(date '+%F %T') $*"; };
fi

# Debug mode: enable with XMP_DEBUG=1/true/yes
DEBUG_ON=0
case "${XMP_DEBUG:-0}" in
    1|true|TRUE|yes|YES) DEBUG_ON=1 ;;
esac

# Helper to validate integers
is_digits() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

produce_files() {
    if [ "$INPUT_TYPE" = dir ]; then
        find "$INPUT" -type f \
            ! -iname '*.xmp' \
            ! -iname '*.log' \
            ! -iname '*.json' \
            ! -iname '*.session' \
            -name '*.*' \
            -print0
    else
        # Single file; exclude it if it is among those to ignore
        lc=$(echo "$INPUT" | tr '[:upper:]' '[:lower:]')
        case "$lc" in
            *.xmp|*.log|*.json|*.session)
                return 0 ;;
        esac
        printf '%s\0' "$INPUT"
    fi
}

produce_files | while IFS= read -r -d '' img; do
    xmp="${img}.xmp"

    if [ -f "$xmp" ]; then
        # Suppress minor warnings and unnecessary exiftool output (-m -q -q)
        # Try a series of tags for the original date (images and videos)
        orig_dt=$(exiftool -m -q -q -s -s -s -d %s -DateTimeOriginal "$img")
        create_dt=$(exiftool -m -q -q -s -s -s -d %s -CreateDate "$img")
        orig_epoch=""
        if is_digits "$orig_dt"; then
            orig_epoch="$orig_dt"
        fi
        if is_digits "$create_dt"; then
            if [ -z "$orig_epoch" ] || [ "$create_dt" -lt "$orig_epoch" ]; then
                orig_epoch="$create_dt"
            fi
        fi

        xmp_dt=$(exiftool -m -q -q -s -s -s -d %s -XMP:DateTimeOriginal "$xmp")
        xmp_create_dt=$(exiftool -m -q -q -s -s -s -d %s -XMP:CreateDate "$xmp")
        xmp_epoch=""
        if is_digits "$xmp_dt"; then
            xmp_epoch="$xmp_dt"
        fi
        if is_digits "$xmp_create_dt"; then
            if [ -z "$xmp_epoch" ] || [ "$xmp_create_dt" -lt "$xmp_epoch" ]; then
                xmp_epoch="$xmp_create_dt"
            fi
        fi

        # Validate that they are numbers, otherwise zero them to avoid "bad number"
        is_digits "$orig_epoch" || orig_epoch=""
        is_digits "$xmp_epoch" || xmp_epoch=""

        # Get the oldest date string compared to the original
        if [ -n "$orig_epoch" ] && is_digits "$orig_epoch"; then
            # date -d "@<epoch>" produces the local date. If it fails we leave it empty.
            orig_date_str=$(date -d "@$orig_epoch" '+%Y:%m:%d %H:%M:%S' 2>/dev/null || true)
        else
            orig_date_str=""
        fi

        if [ -n "$xmp_epoch" ] && [ -n "$orig_epoch" ] && [ "$xmp_epoch" -gt "$orig_epoch" ]; then
            if [ -n "$orig_date_str" ]; then
                log "Fixing XMP date (newer than original): $img"
                exiftool -m -q -q -overwrite_original -XMP:CreateDate="$orig_date_str" -XMP:DateTimeOriginal="$orig_date_str" "$xmp" >/dev/null 2>&1 || log "exiftool date copy failed for $img"
            else
                log "WARNING: Cannot fix XMP date for $img - no original date string found"
            fi
        elif [ "$DEBUG_ON" -eq 1 ]; then
            if [ -z "$orig_epoch" ] || [ -z "$xmp_epoch" ]; then
                log "WARNING: No EXIF date found for $img in original file and/or XMP sidecar"
            else
                log "WARNING: XMP date is not newer than original for $img; no action taken"
            fi
        fi

        # If the xmp_epoch value is still older than the original, fix it (it can happen if the original date was moved forward)
        if [ -n "$xmp_epoch" ] && [ -n "$orig_epoch" ] && [ "$xmp_epoch" -lt "$orig_epoch" ]; then
            if [ -n "$orig_date_str" ]; then
                orig_date_str_temp=$(date -d "@$xmp_epoch" '+%Y:%m:%d %H:%M:%S' 2>/dev/null || true)
                if [ -n "$orig_date_str_temp" ]; then
                    if [ "$DEBUG_ON" -eq 1 ]; then
                        log "DEBUG: XMP date is older than original for $img; fixing local script value to $orig_date_str_temp"
                    fi
                    orig_date_str="$orig_date_str_temp"
                fi
            fi
        fi

        # Check and fix photoshop:DateCreated if present and newer
        if [ -n "$orig_date_str" ]; then
            ps_date=$(exiftool -m -q -q -s -s -s -d %s -Photoshop:DateCreated "$xmp")
            if [ -n "$ps_date" ] && is_digits "$ps_date" && [ "$ps_date" -gt "$orig_epoch" ]; then
                log "Fixing Photoshop date (newer than original): $img"
                exiftool -m -q -q -overwrite_original -Photoshop:DateCreated="$orig_date_str" "$xmp" >/dev/null 2>&1 || log "exiftool photoshop date copy failed for $xmp"
            fi
        fi

        # Check and fix exif:GPSTimeStamp if present and newer
        if [ -n "$orig_date_str" ]; then
            gps_epoch=$(exiftool -m -q -q -s -s -s -d %s -GPSDateTime "$xmp")
            if [ -n "$gps_epoch" ] && is_digits "$gps_epoch" && [ "$gps_epoch" -gt "$orig_epoch" ]; then
                log "Fixing GPS date (newer than original): $img"
                exiftool -m -q -q -overwrite_original -GPSDateTime="$orig_date_str" "$xmp" >/dev/null 2>&1 || log "exiftool gps date copy failed for $xmp"
            fi
        fi
    else
        log "WARNING: Missing XMP sidecar for $img"
    fi
done