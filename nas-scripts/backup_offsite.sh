#!/usr/bin/env bash
set -euo pipefail

# Ignore SIGHUP to survive the terminal being closed
trap '' HUP

# =============================================================================
# OFFSITE BACKUP — Borg (Proton mirror via proton_cli_backup.sh + timer)
# =============================================================================
# Incremental backup with Borg. Mirror to Proton Drive through the official CLI
# (proton_cli_backup.sh, systemd user timer).
# Recommended cron: 0 3 * * * /mnt/nas2/nas-scripts/backup_offsite.sh
#
# Backed-up sources:
#   docker/data/: certbot, icloud-photos, immich,
#                 nginx, jellyfin, nextcloud (excl. db/),
#                 nextcloud-db-dumps, sqlite-snapshots, vaultwarden,
#                 syncthing/obsidian (excl. com.whatsapp)
#   docker/:      kickstart, scripts,
#                 docker-compose.yml, .env, *.sh
#   nas2/:        media (ebooks+music), nas-scripts,
#
# DB dumps before borg:
#   - immich postgres -> data/immich/db_dump.sql.gz (overwritten every run)
#   - nextcloud mariadb -> data/nextcloud-db-dumps/nextcloud-N.sql.gz (7-day rotation)
#   - sqlite (vaultwarden, jellyfin) -> data/sqlite-snapshots/ (lock-safe)
# =============================================================================

REPO="/mnt/nas/backup/offsite"
PASSPHRASE_FILE="/home/REDACTED_HOSTNAME/.borg-offsite-passphrase"
LOGFILE="/var/log/backup-offsite.log"
LOCKFILE="/tmp/backup-offsite.lock"
HOSTNAME="$(hostname -s)"
DATE="$(date +%Y-%m-%d_%H-%M)"
ARCHIVE="${HOSTNAME}-${DATE}"

# Sources
DOCKER_DIR="/mnt/nas2/docker"
MEDIA_DIR="/mnt/nas2/media"
NAS_SCRIPTS="/mnt/nas2/nas-scripts"
INCUS_CONFIG="/mnt/nas2/incus-config-backup"   # light Incus config (certificates + config, no VMs)

# --- Functions ---------------------------------------------------------------

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

# Send a notification email (uses the shared SMTP from .env, fallback SMART_*)
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

    # Precompute the from-name OUTSIDE the heredoc: a default with an apostrophe
    # (e.g. "REDACTED_BRAND' Services") inside ${var:-...} in a heredoc breaks bash
    # parsing ("bad substitution"). Here the apostrophe is harmless.
    local from_name="${smtp_from_name:-REDACTED_BRAND Services}"

    curl -s --max-time 30 --url "$smtp_url" \
        "${curl_tls[@]}" \
        --mail-from "$smtp_from" \
        --mail-rcpt "$smtp_to" \
        --user "${smtp_user}:${smtp_pass}" \
        -T - <<MAILEOF
From: ${from_name} <${smtp_from}>
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

# --- Pre-checks --------------------------------------------------------------

# Lock: only one backup at a time
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

# Trap for unexpected crashes (set -e): send an email before exiting
on_error() {
    local exit_code=$? lineno=${BASH_LINENO[0]}
    log "CRASH: script terminato inaspettatamente alla riga ${lineno} (exit ${exit_code})"
    send_backup_email "CRASH backup offsite" \
        "Il backup offsite di $(hostname) è CRASHATO il $(date '+%d/%m/%Y %H:%M')."$'\n'$'\n'"Riga: ${lineno} — Exit code: ${exit_code}"$'\n'$'\n'"Controlla il log: /var/log/backup-offsite.log" 2>/dev/null || true
}
trap on_error ERR

# Check the mount
mountpoint -q "/mnt/nas2" || die "/mnt/nas2 non montato"

# Check the passphrase
[ -f "$PASSPHRASE_FILE" ] || die "File passphrase mancante: $PASSPHRASE_FILE"
export BORG_PASSCOMMAND="cat $PASSPHRASE_FILE"

# Check the repo
[ -d "$REPO/data" ] || die "Repo Borg non trovato: $REPO"

# --- Step 1a: Immich PostgreSQL dump -----------------------------------------

log "=== BACKUP OFFSITE START ==="

IMMICH_DUMP="${DOCKER_DIR}/data/immich/db_dump.sql.gz"
if docker ps --format '{{.Names}}' | grep -q '^immich_postgres$'; then
    log "Dump PostgreSQL immich..."
    # The DB superuser is the compose POSTGRES_USER (IMMICH_DB_USERNAME), not "postgres"
    IMMICH_DB_USER=$(grep '^IMMICH_DB_USERNAME=' "${DOCKER_DIR}/.env" | tail -1 | cut -d= -f2- | tr -d "\"'")
    IMMICH_DB_USER=${IMMICH_DB_USER:-immich}
    # Dump to a temporary file: the previous dump is replaced only if the new one is valid
    if docker exec immich_postgres pg_dumpall -U "$IMMICH_DB_USER" 2>>"$LOGFILE" | gzip > "${IMMICH_DUMP}.tmp" \
        && [ "$(stat -c%s "${IMMICH_DUMP}.tmp")" -gt 1024 ]; then
        mv -f "${IMMICH_DUMP}.tmp" "$IMMICH_DUMP"
        log "Dump immich: $(du -h "$IMMICH_DUMP" | cut -f1)"
    else
        rm -f "${IMMICH_DUMP}.tmp"
        log "WARN: pg_dumpall fallito o vuoto, dump precedente mantenuto"
    fi
else
    log "WARN: container immich_postgres non attivo, skip dump DB"
fi

# --- Step 1b: Nextcloud MariaDB dump -----------------------------------------
# The SQL dump is essential for a consistent restore (the MariaDB binary files under
# data/nextcloud/db copied while live can be corrupted). Keeps 7 rotating
# dumps, one per day of the week (overwritten every week).

NC_DUMP_DIR="${DOCKER_DIR}/data/nextcloud-db-dumps"
mkdir -p "$NC_DUMP_DIR"
NC_DUMP="${NC_DUMP_DIR}/nextcloud-$(date +%u).sql.gz"  # 1=Mon .. 7=Sun
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

# --- Step 1c: Consistent SQLite snapshots ------------------------------------
# vaultwarden and jellyfin use SQLite (WAL mode with live writes).
# Copying the file while live can produce corrupted DBs. We use `sqlite3 .backup`
# (host-side, lock-safe via WAL checkpoint). Requires the sqlite3 package.

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

# --- Step 2: Borg create (incremental, deduplicated) -------------------------

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
    "${DOCKER_DIR}/utils.sh" \
    "${MEDIA_DIR}" \
    "${NAS_SCRIPTS}" \
    "${INCUS_CONFIG}" \
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

# Keep the repo readable by REDACTED_HOSTNAME: borg runs as root and creates the 0600 root
# segments; the Proton mirror through the official CLI runs as REDACTED_HOSTNAME (per-user
# keyring) and must be able to read them. The repo is Borg-encrypted: REDACTED_HOSTNAME ownership is OK.
chown -R REDACTED_HOSTNAME:REDACTED_HOSTNAME "${REPO}" 2>/dev/null || true
log "Repo offsite chown -> REDACTED_HOSTNAME (per mirror Proton CLI)"

# --- Step 4: Mirror to Proton Drive -----------------------------------------
# Handled separately by the official Proton CLI (proton_cli_backup.sh) via the
# systemd USER timer "proton-cli-backup.timer" (03:30). Here: only borg + repo chown.

# --- End ---------------------------------------------------------------------

REPO_SIZE=$(du -sh "$REPO" | cut -f1)
log "=== BACKUP OFFSITE DONE === (repo: ${REPO_SIZE})"
