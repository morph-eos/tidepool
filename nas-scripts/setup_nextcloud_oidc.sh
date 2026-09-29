#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# SETUP NEXTCLOUD OIDC — OIDC client redirect URIs managed by Nextcloud
# =============================================================================
# Nextcloud oidc:create does not expose update; to add redirect URIs without
# regenerating client_id/secret we use idempotent inserts on the OIDC app table.
# =============================================================================

DOCKER_DIR="/mnt/nas2/docker"
ENV_FILE="${DOCKER_DIR}/.env"
NC_DB_CONTAINER="nextcloud_mariadb"
NC_CONTAINER="nextcloud"
NC_DB_NAME="nextcloud"

IMMICH_CLIENT_ID="REDACTED_IMMICH_OIDC_CLIENT_ID"
JELLYFIN_CLIENT_ID="REDACTED_JELLYFIN_SSO"
VAULTWARDEN_CLIENT_ID="REDACTED_VAULTWARDEN_SSO_CLIENT_ID"

log() { echo "[nextcloud-oidc] $*"; }
die() { echo "[nextcloud-oidc] ERRORE: $*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Esegui come root: sudo $0"
}

get_db_password() {
    [ -f "$ENV_FILE" ] || die ".env non trovato: $ENV_FILE"
    grep '^NEXTCLOUD_DB_ROOT_PASSWORD=' "$ENV_FILE" | cut -d= -f2-
}

sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

mysql_exec() {
    local query="$1"
    docker exec -e MYSQL_PWD="$NC_DB_PASS" "$NC_DB_CONTAINER" \
        mariadb -u root "$NC_DB_NAME" -N -B -e "$query"
}

ensure_redirect_uri() {
    local client_identifier="$1" redirect_uri="$2"
    local client_sql redirect_sql
    client_sql=$(sql_escape "$client_identifier")
    redirect_sql=$(sql_escape "$redirect_uri")

    local client_pk
    client_pk=$(mysql_exec "SELECT id FROM oc_oidc_clients WHERE client_identifier='${client_sql}' LIMIT 1;" | head -1 || true)
    [ -n "$client_pk" ] || die "Client OIDC non trovato: $client_identifier"

    mysql_exec "
INSERT INTO oc_oidc_redirect_uris (client_id, redirect_uri)
SELECT ${client_pk}, '${redirect_sql}'
WHERE NOT EXISTS (
    SELECT 1 FROM oc_oidc_redirect_uris
    WHERE client_id=${client_pk} AND redirect_uri='${redirect_sql}'
);
" >/dev/null
}

show_status() {
    docker exec -u www-data "$NC_CONTAINER" php occ oidc:list
}

install_oidc_redirects() {
    log "Verifico container Nextcloud/MariaDB..."
    docker ps --format '{{.Names}}' | grep -qx "$NC_CONTAINER" || die "Container $NC_CONTAINER non attivo"
    docker ps --format '{{.Names}}' | grep -qx "$NC_DB_CONTAINER" || die "Container $NC_DB_CONTAINER non attivo"

    log "Aggiungo redirect URI Immich/Jellyfin/Vaultwarden (idempotente)..."
    ensure_redirect_uri "$IMMICH_CLIENT_ID" "https://immich.REDACTED_DOMAIN/auth/login"
    ensure_redirect_uri "$IMMICH_CLIENT_ID" "https://immich.REDACTED_DOMAIN/user-settings"
    ensure_redirect_uri "$IMMICH_CLIENT_ID" "https://immich.REDACTED_HOSTNAME.REDACTED_DDNS/auth/login"
    ensure_redirect_uri "$IMMICH_CLIENT_ID" "https://immich.REDACTED_HOSTNAME.REDACTED_DDNS/user-settings"
    ensure_redirect_uri "$IMMICH_CLIENT_ID" "app.immich:///oauth-callback"
    ensure_redirect_uri "$JELLYFIN_CLIENT_ID" "https://jellyfin.REDACTED_DOMAIN/sso/OID/redirect/nextcloud"
    ensure_redirect_uri "$JELLYFIN_CLIENT_ID" "https://jellyfin.REDACTED_HOSTNAME.REDACTED_DDNS/sso/OID/redirect/nextcloud"
    ensure_redirect_uri "$VAULTWARDEN_CLIENT_ID" "https://bitwarden.REDACTED_DOMAIN/identity/connect/oidc-signin"
    ensure_redirect_uri "$VAULTWARDEN_CLIENT_ID" "https://bitwarden.REDACTED_HOSTNAME.REDACTED_DDNS/identity/connect/oidc-signin"

    log "Redirect URI correnti:"
    show_status
}

usage() {
    cat <<USAGE
Uso: $0 {install|status}

install  Aggiunge/riconcilia redirect URI OIDC Nextcloud
status   Mostra client OIDC registrati
USAGE
}

require_root
NC_DB_PASS=$(get_db_password)
[ -n "$NC_DB_PASS" ] || die "NEXTCLOUD_DB_ROOT_PASSWORD vuoto/non trovato"

case "${1:-install}" in
    install) install_oidc_redirects ;;
    status) show_status ;;
    *) usage; exit 1 ;;
esac