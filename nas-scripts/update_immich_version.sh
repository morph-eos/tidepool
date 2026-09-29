#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# UPDATE IMMICH VERSION — updates the Immich tag in .env and recreates the containers
# =============================================================================
# Usage:
#   sudo /mnt/nas2/nas-scripts/update_immich_version.sh v2.7.5
#   sudo /mnt/nas2/nas-scripts/update_immich_version.sh status   # default without arguments
# =============================================================================

DOCKER_DIR="/mnt/nas2/docker"
ENV_FILE="${DOCKER_DIR}/.env"
TARGET_VERSION="${1:-status}"

log() { echo "[immich-update] $*"; }
die() { echo "[immich-update] ERRORE: $*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Esegui come root: sudo $0 <versione>"
}

current_env_version() {
    grep '^IMMICH_VERSION=' "$ENV_FILE" | cut -d= -f2-
}

server_version() {
    curl -s --max-time 10 http://127.0.0.1:2283/api/server/version 2>/dev/null \
        | jq -r '"v\(.major).\(.minor).\(.patch)"' 2>/dev/null || true
}

show_status() {
    log "IMMICH_VERSION in .env: $(current_env_version 2>/dev/null || echo 'non trovato')"
    log "Versione server API: $(server_version || echo 'non raggiungibile')"
    (cd "$DOCKER_DIR" && docker compose ps immich-server immich-machine-learning immich-database immich-redis)
}

update_env_version() {
    [ -f "$ENV_FILE" ] || die ".env non trovato: $ENV_FILE"
    grep -q '^IMMICH_VERSION=' "$ENV_FILE" || die "IMMICH_VERSION non trovato in $ENV_FILE"

    local current
    current=$(current_env_version)
    if [ "$current" = "$TARGET_VERSION" ]; then
        log ".env già su IMMICH_VERSION=${TARGET_VERSION}"
        return
    fi

    local backup="${ENV_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$ENV_FILE" "$backup"
    sed -i "s/^IMMICH_VERSION=.*/IMMICH_VERSION=${TARGET_VERSION}/" "$ENV_FILE"
    log "Aggiornato IMMICH_VERSION: ${current} -> ${TARGET_VERSION} (backup: ${backup})"
}

apply_update() {
    local before_env before_server
    before_env=$(current_env_version)
    before_server=$(server_version)

    if [ "$before_env" = "$TARGET_VERSION" ] && [ "$before_server" = "$TARGET_VERSION" ]; then
        log "Immich già aggiornato a ${TARGET_VERSION}; nessuna azione necessaria"
        show_status
        return
    fi

    update_env_version

    log "Validazione compose..."
    (cd "$DOCKER_DIR" && docker compose config --quiet)

    log "Pull immagini Immich ${TARGET_VERSION}..."
    (cd "$DOCKER_DIR" && docker compose pull immich-server immich-machine-learning)

    log "Ricreo container Immich..."
    (cd "$DOCKER_DIR" && docker compose up -d immich-server immich-machine-learning)

    log "Ricarico nginx per aggiornare gli upstream Docker..."
    (cd "$DOCKER_DIR" && docker compose exec -T nginx nginx -s reload) || log "WARN: reload nginx fallito"

    log "Attendo avvio server..."
    for _ in $(seq 1 60); do
        local version
        version=$(server_version)
        if [ "$version" = "$TARGET_VERSION" ]; then
            log "Immich aggiornato: ${version}"
            show_status
            return
        fi
        sleep 5
    done

    show_status
    die "Immich non risulta su ${TARGET_VERSION} dopo il timeout"
}

require_root

case "$TARGET_VERSION" in
    status) show_status ;;
    v[0-9]*.[0-9]*.[0-9]*) apply_update ;;
    *) die "Versione non valida: $TARGET_VERSION (es. v2.7.5)" ;;
esac