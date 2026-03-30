#!/bin/bash

# ============================================================================
# IMMICH INITIALIZATION SCRIPT
# ============================================================================
# This script sets up a cron job for automatic photo upload
# from iCloud to Immich every hour
#

# Remove stale lock file if it exists
if [ -f /tmp/immich_upload.lock ]; then
    rm -f /tmp/immich_upload.lock
fi

# Install cron and procps (for pgrep) if not already present
apt-get update -qq && apt-get install -y cron procps

# Create the cron job for automatic upload - 5 minutes after this script starts
crontab -l 2>/dev/null | grep -v 'immich upload' | crontab -

# Calculate the minute to run (current minute + 5)
CURRENT_MINUTE=$(date +%M)
EXEC_MINUTE=$(((CURRENT_MINUTE + 5) % 60))

# Create the upload script with robust lock management and cleanup
cat > /usr/local/bin/immich-upload-script.sh << 'EOF'
#!/bin/bash
set -euo pipefail
source /etc/profile
export PATH=/usr/local/bin:/usr/bin:/bin:$PATH

LOG_FILE=/var/log/immich-upload.log
IMPORT_DIR=/import

mkdir -p "$(dirname "$LOG_FILE")"

echo "$(date): [CRON] Starting check (args: $*)" >> "$LOG_FILE" 2>&1

# Se viene passato CLEANUP_ONLY, salta lock/upload e fa solo cleanup
MODE=${1:-FULL}

# Controlla se il lock file esiste ed è più vecchio di 12 ore (43200 secondi)
if [ "$MODE" != "CLEANUP_ONLY" ]; then
  if [ -f /tmp/immich_upload.lock ]; then
      lock_age=$(( $(date +%s) - $(stat -c %Y /tmp/immich_upload.lock 2>/dev/null || echo 0) ))
      if [ $lock_age -gt 43200 ]; then
          echo "$(date): [CRON] Found stale lock file (age: ${lock_age}s), removing it and closing old process" >> "$LOG_FILE" 2>&1
          pgrep -f "/usr/local/bin/immich upload" | xargs -r kill -9
          rm -f /tmp/immich_upload.lock
      else
          echo "$(date): [CRON] Upload running (lock exists, age: ${lock_age}s), skip" >> "$LOG_FILE" 2>&1
          exit 0
      fi
  fi
fi

# --- FUNZIONE CLEANUP (Retention: mesi + anni vuoti) ---
cleanup_retention() {
  # Calcolo mesi da mantenere (corrente, -1, -2)
  CURRENT_Y=$(date +%Y)
  CURRENT_M=$(date +%m)
  KEEP1_Y=$CURRENT_Y; KEEP1_M=$CURRENT_M
  KEEP2_Y=$(date -d "-1 month" +%Y); KEEP2_M=$(date -d "-1 month" +%m)
  KEEP3_Y=$(date -d "-2 months" +%Y); KEEP3_M=$(date -d "-2 months" +%m)

  # Pattern validi: MM e M (senza zero iniziale)
  KEEP_LIST=("${KEEP1_Y}/${KEEP1_M}" "${KEEP2_Y}/${KEEP2_M}" "${KEEP3_Y}/${KEEP3_M}")
  KEEP_LIST+=("${KEEP1_Y}/$(echo $KEEP1_M | sed 's/^0//')" "${KEEP2_Y}/$(echo $KEEP2_M | sed 's/^0//')" "${KEEP3_Y}/$(echo $KEEP3_M | sed 's/^0//')")

  echo "$(date): [CLEANUP] Keeping months: ${KEEP_LIST[*]}" >> "$LOG_FILE" 2>&1
  echo "$(date): [CLEANUP] Scan under $IMPORT_DIR" >> "$LOG_FILE" 2>&1
  if [ -d "$IMPORT_DIR" ]; then
    find "$IMPORT_DIR" -mindepth 2 -maxdepth 2 -type d \
      | while read -r path; do
          y=$(basename "$(dirname "$path")"); m=$(basename "$path")
          if [[ "$y" =~ ^[0-9]{4}$ ]] && [[ "$m" =~ ^(0?[1-9]|1[0-2])$ ]]; then
            ym="$y/$m"; keep=false
            for k in "${KEEP_LIST[@]}"; do [ "$ym" = "$k" ] && keep=true && break; done
            if [ "$keep" = true ]; then
              echo "$(date): [CLEANUP] Keep: $path" >> "$LOG_FILE" 2>&1
            else
              echo "$(date): [CLEANUP] Remove: $path" >> "$LOG_FILE" 2>&1
              rm -rf --one-file-system "$path" >> "$LOG_FILE" 2>&1 || echo "$(date): [CLEANUP] Failed to remove $path" >> "$LOG_FILE" 2>&1
            fi
          else
            echo "$(date): [CLEANUP] Skip (not YYYY/MM): $path" >> "$LOG_FILE" 2>&1
          fi
        done
  else
    echo "$(date): [CLEANUP] Import directory not found: $IMPORT_DIR" >> "$LOG_FILE" 2>&1
  fi

  # Rimozione cartelle anno vuote (solo veramente vuote)
  echo "$(date): [CLEANUP] Checking empty year directories under $IMPORT_DIR" >> "$LOG_FILE" 2>&1
  if [ -d "$IMPORT_DIR" ]; then
    find "$IMPORT_DIR" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended -regex '.*/[0-9]{4}$' \
      | while read -r ydir; do
          if [ -z "$(find "$ydir" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
            echo "$(date): [CLEANUP] Remove empty year: $ydir" >> "$LOG_FILE" 2>&1
            rmdir "$ydir" >> "$LOG_FILE" 2>&1 || echo "$(date): [CLEANUP] Could not remove (not empty?): $ydir" >> "$LOG_FILE" 2>&1
          else
            echo "$(date): [CLEANUP] Keep year (not empty): $ydir" >> "$LOG_FILE" 2>&1
          fi
        done
  fi
}

# Modalità solo cleanup (manuale)
if [ "$MODE" = "CLEANUP_ONLY" ]; then
  cleanup_retention
  echo "$(date): [CLEANUP] Done (cleanup-only)" >> "$LOG_FILE" 2>&1
  exit 0
fi

# --- UPLOAD ESECUZIONE ---
echo "$(date): [CRON] Starting upload" >> "$LOG_FILE" 2>&1
: > /tmp/immich_upload.lock
trap 'rm -f /tmp/immich_upload.lock' EXIT

# Esegui l'upload appending direttamente al LOG_FILE
timeout 36000 /usr/local/bin/immich upload --url http://localhost:2283/api --key ${IMMICH_API_KEY} --recursive "$IMPORT_DIR" >> "$LOG_FILE" 2>&1
UPLOAD_EXIT=$?

# Controllo basato sull'ultima riga del log principale
LAST_LINE=$(tail -n 1 "$LOG_FILE" | tr -d '\r')
UPLOAD_OK=false
if echo "$LAST_LINE" | grep -Fqx "All assets were already uploaded, nothing to do."; then
  UPLOAD_OK=true
else
  UPLOAD_OK=false
fi

rm -f /tmp/immich_upload_lock 2>/dev/null || true
rm -f /tmp/immich_upload.lock
trap - EXIT

echo "$(date): [CRON] Upload done, exit: $UPLOAD_EXIT | success_by_last_line: $UPLOAD_OK | last_line: $LAST_LINE" >> "$LOG_FILE" 2>&1

# Esegui retention SOLO se il log indica esito OK (ultima riga)
if [ "$UPLOAD_OK" = true ]; then
  echo "$(date): [CRON] Upload log indicates success, running retention cleanup" >> "$LOG_FILE" 2>&1
  cleanup_retention
  echo "$(date): [CLEANUP] Completed after successful upload" >> "$LOG_FILE" 2>&1
else
  echo "$(date): [CRON] Upload did not indicate success in log, skipping retention cleanup" >> "$LOG_FILE" 2>&1
fi
EOF

# Inietta l'API key nello script (necessario perché cron non eredita l'ambiente Docker), dopo lo shebang
if [ -n "${IMMICH_API_KEY}" ]; then
  sed -i "2iexport IMMICH_API_KEY='${IMMICH_API_KEY//\'/\'\"\'\"\'}'" /usr/local/bin/immich-upload-script.sh
fi

# Make the script executable
chmod +x /usr/local/bin/immich-upload-script.sh

# Create the cron job for automatic upload every hour
crontab -l 2>/dev/null | grep -v 'immich-upload-script' | crontab -
echo "${EXEC_MINUTE} * * * * /usr/local/bin/immich-upload-script.sh" | crontab -


# Start the cron service
service cron start

# Confirmation log
echo "$(date): Cron job configured for automatic Immich upload"
echo "$(date): Next upload will run at minute ${EXEC_MINUTE} of every hour unless a previous upload is still running"
echo "$(date): Monitored directory: /import"

# Execute the original Immich server using the correct start script
exec /bin/bash -c "start.sh"
