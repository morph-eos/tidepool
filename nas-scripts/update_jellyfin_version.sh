#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# UPDATE JELLYFIN VERSION — updates the Jellyfin tag+digest in docker-compose.yml,
# backs up the config before the DB migration, recreates the container, verifies.
# =============================================================================
# Usage:
#   sudo /mnt/nas2/nas-scripts/update_jellyfin_version.sh 12.1
#   sudo /mnt/nas2/nas-scripts/update_jellyfin_version.sh status
# =============================================================================
# Note: unlike Immich (tag in .env), Jellyfin is pinned by
# tag@sha256 directly in docker-compose.yml — the script resolves the current
# digest of the pulled image and writes it into the compose, as per the convention
# of the rest of the stack.
#
# The Jellyfin DB migrations (EF Core, from 12.0 onwards) are one-way:
# a simple tag downgrade is NOT enough to go back. For this reason the script always
# takes a full backup of docker/data/jellyfin/config BEFORE touching the container,
# alongside the internal backup that Jellyfin makes of its own jellyfin.db.

DOCKER_DIR="/mnt/nas2/docker"
COMPOSE_FILE="${DOCKER_DIR}/docker-compose.yml"
BACKUP_ROOT="${DOCKER_DIR}/backups"
TARGET_VERSION="${1:-12.1}"

log() { echo "[jellyfin-update] $*"; }
die() { echo "[jellyfin-update] ERRORE: $*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Esegui come root: sudo $0 <versione|status>"
}

current_tag() {
    grep -oP '(?<=image: jellyfin/jellyfin:)[^@]+' "$COMPOSE_FILE" | head -1
}

server_version() {
    docker exec jellyfin cat /config/data/jellyfin.db >/dev/null 2>&1 || true
    curl -s --max-time 10 http://127.0.0.1:8096/System/Info/Public 2>/dev/null \
        | grep -oP '(?<="Version":")[^"]+' || true
}

show_status() {
    log "Tag in docker-compose.yml: $(current_tag 2>/dev/null || echo 'non trovato')"
    log "Versione server (API pubblica): $(server_version || echo 'non raggiungibile')"
    (cd "$DOCKER_DIR" && docker compose ps jellyfin)
}

apply_update() {
    local before_tag
    before_tag=$(current_tag)
    if [ "$before_tag" = "$TARGET_VERSION" ]; then
        log "docker-compose.yml già su jellyfin:${TARGET_VERSION}; nessuna azione necessaria"
        show_status
        return
    fi

    log "Pull immagine jellyfin/jellyfin:${TARGET_VERSION}..."
    docker pull "jellyfin/jellyfin:${TARGET_VERSION}"
    local digest
    digest=$(docker inspect "jellyfin/jellyfin:${TARGET_VERSION}" --format '{{index .RepoDigests 0}}' | cut -d@ -f2)
    [ -n "$digest" ] || die "Impossibile risolvere il digest per ${TARGET_VERSION}"

    local ts backup_dir
    ts=$(date +%Y%m%d-%H%M%S)
    backup_dir="${BACKUP_ROOT}/jellyfin-config-pre-${TARGET_VERSION}-${ts}"
    log "Fermo jellyfin e prendo backup config in ${backup_dir}..."
    (cd "$DOCKER_DIR" && docker compose stop jellyfin)
    mkdir -p "$backup_dir"
    cp -a "${DOCKER_DIR}/data/jellyfin/config" "$backup_dir/"
    log "Backup completato: $(du -sh "$backup_dir" | cut -f1)"

    local compose_backup="${COMPOSE_FILE}.bak.${ts}"
    cp -a "$COMPOSE_FILE" "$compose_backup"
    sed -i "s|image: jellyfin/jellyfin:[^[:space:]]*|image: jellyfin/jellyfin:${TARGET_VERSION}@sha256:${digest}|" "$COMPOSE_FILE"
    log "docker-compose.yml aggiornato: ${before_tag} -> ${TARGET_VERSION} (backup: ${compose_backup})"

    (cd "$DOCKER_DIR" && docker compose config --quiet)
    log "Ricreo container jellyfin..."
    (cd "$DOCKER_DIR" && docker compose up -d jellyfin)

    log "Attendo avvio/migrazioni (possono richiedere qualche minuto)..."
    for _ in $(seq 1 60); do
        local version
        version=$(server_version)
        if [ -n "$version" ]; then
            log "Jellyfin risponde: ${version}"
            break
        fi
        sleep 5
    done

    log "Ricarico nginx per aggiornare l'upstream Docker..."
    (cd "$DOCKER_DIR" && docker compose exec -T nginx nginx -s reload) || log "WARN: reload nginx fallito"

    log "Controllo plugin in attesa di restart (SSO-Auth/Trakt vengono spesso auto-aggiornati)..."
    sleep 3
    if docker logs jellyfin --since 2m 2>&1 | grep -q "Restart"; then
        log "Rilevati plugin in stato 'Restart', riavvio jellyfin per attivarli..."
        docker restart jellyfin
        sleep 10
    fi

    show_status
    log "Verifica manualmente: pagina di login, flusso SSO (/sso/OID/start/nextcloud), transcoding hardware."
}

require_root

case "$TARGET_VERSION" in
    status) show_status ;;
    [0-9]*.[0-9]*) apply_update ;;
    *) die "Versione non valida: $TARGET_VERSION (es. 12.1)" ;;
esac
