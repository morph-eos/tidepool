#!/usr/bin/env bash
# =============================================================================
# Mirror of the "offsite" Borg repo to Proton Drive via the OFFICIAL CLI (proton-drive).
# Incremental mirror of the offsite Borg repo to Proton Drive (official CLI).
#
# Self-healing / reconciling:
#   - repo metadata (config, nonce, README, hints.*, index.*, integrity.*):
#     upload with the "replace" strategy (updates the mutable ones, adds the new generations)
#   - data/ segments (immutable): upload with "skip" (uploads only the new ones)
#   - ORPHANS: compares the remote tree with the local one and moves to the remote trash
#     the files no longer present (old metadata generations, segments removed
#     by compaction, leftovers of old uploads)
#
# Runs as REDACTED_HOSTNAME; requires the user D-Bus + an unlocked keyring. For
# automation use a systemd USER timer (inherits the session bus).
# Conservative: no aggressive retries (Proton anti-abuse).
# =============================================================================
set -uo pipefail
TARGET_USER=REDACTED_HOSTNAME
if [ "$(id -un)" != "$TARGET_USER" ]; then
    echo "Esegui come $TARGET_USER (NON root): sudo -u $TARGET_USER $0"; exit 1
fi

# Session bus (for the keyring); if not already in the environment (e.g. cron), derive it
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

BIN=/usr/local/bin/proton-drive
REPO=/mnt/nas/backup/offsite
REMOTE=/my-files/backup/tidepool
MANIFEST="$REPO/.proton-cli-manifest"
LOG=/var/log/proton-cli-backup.log
LOCK=/tmp/proton-cli-backup.lock

log(){ echo "$(date -Is) - $*" >> "$LOG" 2>/dev/null; echo "$*"; }
PD(){ "$BIN" "$@"; }

# Upload/reconciliation error counter: if >0 at the end of the run -> alert email.
FAILED=0

# Send a notification email (same SMTP logic as backup_offsite.sh: reads .env,
# fallback to SMART_*). Best-effort: must never make the mirror fail.
ENV_FILE="/mnt/nas2/docker/.env"
send_alert_email(){
    local subject="$1" body="$2"
    [ -f "$ENV_FILE" ] || { log "WARN: .env non trovato, email non inviata"; return 1; }
    env_get(){ grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- | sed -E 's/^"(.*)"$/\1/'; }
    local smtp_host smtp_port smtp_user smtp_pass smtp_from smtp_from_name smtp_to smtp_ssl smtp_tls smtp_url
    smtp_host=$(env_get SMTP_HOST); smtp_host=${smtp_host:-$(env_get SMART_SMTP_HOST)}
    smtp_port=$(env_get SMTP_PORT); smtp_port=${smtp_port:-$(env_get SMART_SMTP_PORT)}
    smtp_user=$(env_get SMTP_USERNAME); smtp_user=${smtp_user:-$(env_get SMART_SMTP_USERNAME)}
    smtp_pass=$(env_get SMTP_PASSWORD); smtp_pass=${smtp_pass:-$(env_get SMART_SMTP_PASSWORD)}
    smtp_from=$(env_get SMTP_FROM); smtp_from=${smtp_from:-$(env_get SMART_SMTP_FROM)}
    smtp_from_name=$(env_get SMTP_FROM_NAME); smtp_from_name=${smtp_from_name:-$(env_get SMART_SMTP_FROM_NAME)}
    smtp_ssl=$(env_get SMTP_SSL); smtp_ssl=${smtp_ssl:-$(env_get SMART_SMTP_SSL)}
    smtp_tls=$(env_get SMTP_EXPLICIT_TLS); smtp_tls=${smtp_tls:-$(env_get SMART_SMTP_EXPLICIT_TLS)}
    smtp_to=$(env_get SMART_ALERT_EMAIL)
    if [ -z "$smtp_host" ] || [ -z "$smtp_to" ]; then
        log "WARN: variabili SMTP incomplete, email non inviata"; return 1
    fi
    if [ "$smtp_ssl" = "true" ]; then smtp_url="smtps://${smtp_host}:${smtp_port}"; else smtp_url="smtp://${smtp_host}:${smtp_port}"; fi
    local curl_tls=()
    [ "$smtp_ssl" = "true" ] || [ "$smtp_tls" = "true" ] && curl_tls=(--ssl-reqd)
    # from-name precomputed outside the heredoc (apostrophe in ${var:-...} inside a
    # heredoc breaks bash parsing). See the same fix in backup_offsite.sh.
    local from_name="${smtp_from_name:-REDACTED_BRAND Services}"
    curl -s --max-time 30 --url "$smtp_url" "${curl_tls[@]}" \
        --mail-from "$smtp_from" --mail-rcpt "$smtp_to" --user "${smtp_user}:${smtp_pass}" \
        -T - <<MAILEOF && log "Email inviata: ${subject}" || log "WARN: invio email fallito: ${subject}"
From: ${from_name} <${smtp_from}>
To: ${smtp_to}
Subject: [REDACTED_HOSTNAME backup] ${subject}
Content-Type: text/plain; charset=utf-8
Date: $(date -R)

${body}
MAILEOF
}

[ -x "$BIN" ] || { echo "proton-drive non installato (setup_proton_cli_backup.sh)"; exit 1; }
[ -d "$REPO/data" ] || { echo "repo Borg offsite non trovato: $REPO"; exit 1; }

# Lock
if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
    echo "Mirror gia' in corso"; exit 0
fi
echo $$ > "$LOCK"; trap 'rm -f "$LOCK"' EXIT

# Auth guard (cron-safe)
if ! PD filesystem list / >/dev/null 2>&1; then
    log "NON autenticato / keyring locked: salto (eseguire 'proton-drive auth login')"; exit 0
fi

log "=== MIRROR PROTON (CLI) START ==="

# Remote folders
PD filesystem create-folder /my-files backup >/dev/null 2>&1 || true
PD filesystem create-folder /my-files/backup tidepool >/dev/null 2>&1 || true

# Helper: list a remote folder -> "name<TAB>type" rows
rlist(){ PD filesystem list -j "$1" 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
for o in d:
    n=o.get("name",{}).get("value"); t=o.get("type")
    if n: print("%s\t%s"%(n,t))'; }

# 1) Metadata -> replace
META=()
for f in config nonce README hints.* index.* integrity.*; do
    for p in "$REPO"/$f; do [ -f "$p" ] && META+=("$p"); done
done
if [ "${#META[@]}" -gt 0 ]; then
    log "Upload metadati (${#META[@]} file, replace)"
    PD filesystem upload -d merge -f replace -t "${META[@]}" "$REMOTE" >>"$LOG" 2>&1 || { log "WARN: upload metadati con errori"; FAILED=$((FAILED+1)); }
fi

# 2) Data -> skip (upload only the new immutable segments)
log "Upload data/ (skip esistenti)"
PD filesystem upload -d merge -f skip -t "$REPO/data" "$REMOTE" >>"$LOG" 2>&1 || { log "WARN: upload data/ con errori"; FAILED=$((FAILED+1)); }

# 3) Orphan reconciliation: remote - local -> delete
LOCAL=$(mktemp); REMOTEF=$(mktemp)
( cd "$REPO" && find . -type f ! -name '.proton-cli-manifest' | sed 's|^\./||' ) | sort -u > "$LOCAL"
# root
while IFS=$'\t' read -r name typ; do [ "$typ" = "file" ] && echo "$name"; done < <(rlist "$REMOTE") >> "$REMOTEF"
# data/<N>/<seg>
while IFS=$'\t' read -r d typ; do
    [ "$typ" = "folder" ] || continue
    while IFS=$'\t' read -r f ftyp; do [ "$ftyp" = "file" ] && echo "data/$d/$f"; done < <(rlist "$REMOTE/data/$d")
done < <(rlist "$REMOTE/data") >> "$REMOTEF"
sort -u -o "$REMOTEF" "$REMOTEF"
DEL=0
while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    PD filesystem trash "$REMOTE/$rel" >>"$LOG" 2>&1 && DEL=$((DEL+1)) || { log "WARN: delete fallita $rel"; FAILED=$((FAILED+1)); }
    sleep 0.3
done < <(comm -23 "$REMOTEF" "$LOCAL")
[ "$DEL" -gt 0 ] && log "Orfani rimossi dal remoto: $DEL"

# 4) Informational manifest
cp -f "$LOCAL" "$MANIFEST" 2>/dev/null || true
rm -f "$LOCAL" "$REMOTEF"

# 5) Alert email if the mirror had errors (consistent with backup_offsite.sh)
if [ "$FAILED" -gt 0 ]; then
    log "Mirror Proton terminato con ${FAILED} errori -> invio alert email"
    send_alert_email "ERRORE mirror Proton Drive" \
"Il mirror su Proton Drive di $(hostname) ha avuto ${FAILED} errori il $(date '+%d/%m/%Y %H:%M').

Il backup Borg locale (offsite + REDACTED_DRIVE) potrebbe essere OK: questo riguarda SOLO
la copia cloud su Proton Drive.

Controlla il log: ${LOG}" || true
fi

log "=== MIRROR PROTON (CLI) DONE (file locali: $(wc -l < "$MANIFEST"), errori: ${FAILED}) ==="
