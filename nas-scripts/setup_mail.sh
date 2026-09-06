#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# SETUP MAIL — Configurazione SMTP condivisa per servizi REDACTED_BRAND
# =============================================================================

DOCKER_DIR="/mnt/nas2/docker"
ENV_FILE="${DOCKER_DIR}/.env"
VW_CONFIG="${DOCKER_DIR}/data/vaultwarden/config.json"
NC_CONTAINER="nextcloud"

SMTP_HOST_VALUE="smtp-relay.REDACTED_SMTP_PROVIDER.com"
SMTP_PORT_VALUE="587"
SMTP_USERNAME_VALUE="REDACTED_SMTP_ACCOUNT"
SMTP_PASSWORD_VALUE=""
SMTP_FROM_VALUE="REDACTED_SERVICE_EMAIL"
SMTP_FROM_NAME_VALUE="REDACTED_BRAND' Services"
SMTP_SSL_VALUE="false"
SMTP_EXPLICIT_TLS_VALUE="true"
NEXTCLOUD_SMTP_SECURE_VALUE="tls"

log() { echo "[mail-setup] $*"; }
die() { echo "[mail-setup] ERRORE: $*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Esegui come root: sudo $0"
}

set_env_key() {
    local key="$1" value="$2" escaped
    escaped=$(printf '%s' "$value" | sed 's/[&\\]/\\&/g')
    if grep -qE "^${key}=" "$ENV_FILE"; then
        sed -i -E "s|^${key}=.*|${key}=${escaped}|" "$ENV_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
}

env_value() {
    local key="$1" line value
    line=$(grep -E "^${key}=" "$ENV_FILE" | tail -1 || true)
    [ -n "$line" ] || return 0
    value="${line#*=}"
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
        value="${value:1:${#value}-2}"
    fi
    printf '%s' "$value"
}

load_smtp_secret() {
    SMTP_PASSWORD_VALUE=$(env_value SMTP_PASSWORD)
    [ -n "$SMTP_PASSWORD_VALUE" ] || SMTP_PASSWORD_VALUE=$(env_value BITWARDEN_SMTP_PASSWORD)
    [ -n "$SMTP_PASSWORD_VALUE" ] || SMTP_PASSWORD_VALUE=$(env_value SMART_SMTP_PASSWORD)
    [ -n "$SMTP_PASSWORD_VALUE" ] || die "Password SMTP non trovata in $ENV_FILE"
}

ensure_env() {
    [ -f "$ENV_FILE" ] || die ".env non trovato: $ENV_FILE"
    load_smtp_secret
    local backup="${ENV_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$ENV_FILE" "$backup"
    log "Backup .env: $backup"

    set_env_key SMTP_HOST "$SMTP_HOST_VALUE"
    set_env_key SMTP_PORT "$SMTP_PORT_VALUE"
    set_env_key SMTP_USERNAME "$SMTP_USERNAME_VALUE"
    set_env_key SMTP_PASSWORD "$SMTP_PASSWORD_VALUE"
    set_env_key SMTP_FROM "$SMTP_FROM_VALUE"
    set_env_key SMTP_FROM_NAME "\"$SMTP_FROM_NAME_VALUE\""
    set_env_key SMTP_SSL "$SMTP_SSL_VALUE"
    set_env_key SMTP_EXPLICIT_TLS "$SMTP_EXPLICIT_TLS_VALUE"

    set_env_key NEXTCLOUD_SMTP_HOST "$SMTP_HOST_VALUE"
    set_env_key NEXTCLOUD_SMTP_PORT "$SMTP_PORT_VALUE"
    set_env_key NEXTCLOUD_SMTP_SECURE "$NEXTCLOUD_SMTP_SECURE_VALUE"
    set_env_key NEXTCLOUD_SMTP_AUTHTYPE LOGIN
    set_env_key NEXTCLOUD_SMTP_NAME "$SMTP_USERNAME_VALUE"
    set_env_key NEXTCLOUD_SMTP_PASSWORD "$SMTP_PASSWORD_VALUE"
    set_env_key NEXTCLOUD_MAIL_FROM_ADDRESS "${SMTP_FROM_VALUE%@*}"
    set_env_key NEXTCLOUD_MAIL_DOMAIN "${SMTP_FROM_VALUE#*@}"

    set_env_key BITWARDEN_SMTP_HOST "$SMTP_HOST_VALUE"
    set_env_key BITWARDEN_SMTP_PORT "$SMTP_PORT_VALUE"
    set_env_key BITWARDEN_SMTP_SSL "$SMTP_SSL_VALUE"
    set_env_key BITWARDEN_SMTP_EXPLICIT_TLS "$SMTP_EXPLICIT_TLS_VALUE"
    set_env_key BITWARDEN_SMTP_FROM "$SMTP_FROM_VALUE"
    set_env_key BITWARDEN_SMTP_FROM_NAME "\"$SMTP_FROM_NAME_VALUE\""
    set_env_key BITWARDEN_SMTP_USERNAME "$SMTP_USERNAME_VALUE"
    set_env_key BITWARDEN_SMTP_PASSWORD "$SMTP_PASSWORD_VALUE"

    set_env_key SMART_SMTP_HOST "$SMTP_HOST_VALUE"
    set_env_key SMART_SMTP_PORT "$SMTP_PORT_VALUE"
    set_env_key SMART_SMTP_USERNAME "$SMTP_USERNAME_VALUE"
    set_env_key SMART_SMTP_PASSWORD "$SMTP_PASSWORD_VALUE"
    set_env_key SMART_SMTP_FROM "$SMTP_FROM_VALUE"
    set_env_key SMART_SMTP_FROM_NAME "\"$SMTP_FROM_NAME_VALUE\""
    set_env_key SMART_SMTP_SSL "$SMTP_SSL_VALUE"
    set_env_key SMART_SMTP_EXPLICIT_TLS "$SMTP_EXPLICIT_TLS_VALUE"
}

configure_nextcloud_now() {
    docker ps --format '{{.Names}}' | grep -qx "$NC_CONTAINER" || { log "Nextcloud non attivo; salto apply runtime"; return 0; }
    log "Applico SMTP a Nextcloud runtime..."
    docker exec -u www-data "$NC_CONTAINER" php occ config:system:set mail_smtpmode --value=smtp >/dev/null
    docker exec -u www-data "$NC_CONTAINER" php occ config:system:set mail_smtphost --value="$SMTP_HOST_VALUE" >/dev/null
    docker exec -u www-data "$NC_CONTAINER" php occ config:system:set mail_smtpport --value="$SMTP_PORT_VALUE" >/dev/null
    docker exec -u www-data "$NC_CONTAINER" php occ config:system:set mail_smtpsecure --value="$NEXTCLOUD_SMTP_SECURE_VALUE" >/dev/null
    docker exec -u www-data "$NC_CONTAINER" php occ config:system:set mail_smtpauth --value=1 >/dev/null
    docker exec -u www-data "$NC_CONTAINER" php occ config:system:set mail_smtpauthtype --value=LOGIN >/dev/null
    docker exec -u www-data "$NC_CONTAINER" php occ config:system:set mail_smtpname --value="$SMTP_USERNAME_VALUE" >/dev/null
    docker exec -u www-data "$NC_CONTAINER" php occ config:system:set mail_smtppassword --value="$SMTP_PASSWORD_VALUE" >/dev/null
    docker exec -u www-data "$NC_CONTAINER" php occ config:system:set mail_from_address --value="${SMTP_FROM_VALUE%@*}" >/dev/null
    docker exec -u www-data "$NC_CONTAINER" php occ config:system:set mail_domain --value="${SMTP_FROM_VALUE#*@}" >/dev/null
}

configure_vaultwarden_config() {
    [ -f "$VW_CONFIG" ] || { log "Vaultwarden config non trovato; verrà gestito dalle env al prossimo start"; return 0; }
    command -v jq >/dev/null || die "jq non trovato, impossibile aggiornare JSON Vaultwarden in modo sicuro"
    log "Aggiorno config JSON Vaultwarden..."
    local tmp
    tmp=$(mktemp)
    jq \
      --arg host "$SMTP_HOST_VALUE" \
      --argjson port "$SMTP_PORT_VALUE" \
      --arg from "$SMTP_FROM_VALUE" \
      --arg from_name "$SMTP_FROM_NAME_VALUE" \
      --arg username "$SMTP_USERNAME_VALUE" \
      --arg password "$SMTP_PASSWORD_VALUE" \
      '.smtp_host=$host
       | .smtp_port=$port
       | .smtp_security="starttls"
       | .smtp_from=$from
       | .smtp_from_name=$from_name
       | .smtp_username=$username
       | .smtp_password=$password
       | ._enable_smtp=true' "$VW_CONFIG" > "$tmp"
    install -m 600 "$tmp" "$VW_CONFIG"
    rm -f "$tmp"
}

show_status() {
    echo "=== SMTP condiviso (.env) ==="
    grep -nE '^(SMTP_|NEXTCLOUD_SMTP_|NEXTCLOUD_MAIL_|BITWARDEN_SMTP_|SMART_SMTP_)' "$ENV_FILE" \
        | sed -E 's/(PASSWORD=).*/\1<configurata>/; s/(SMTP_NAME=).*/\1<configurata>/; s/(SMTP_USERNAME=).*/\1<configurata>/'
    echo
    if docker ps --format '{{.Names}}' | grep -qx "$NC_CONTAINER"; then
        echo "=== Nextcloud ==="
        for key in mail_smtpmode mail_smtphost mail_smtpport mail_smtpsecure mail_smtpauth mail_smtpauthtype mail_smtpname mail_from_address mail_domain; do
            printf '  %s=%s\n' "$key" "$(docker exec -u www-data "$NC_CONTAINER" php occ config:system:get "$key" 2>/dev/null || true)"
        done
        printf '  mail_smtppassword=%s\n' "$(docker exec -u www-data "$NC_CONTAINER" php occ config:system:get mail_smtppassword >/dev/null 2>&1 && echo '<configurata>' || echo '<non configurata>')"
    fi
    if [ -f "$VW_CONFIG" ]; then
        echo
        echo "=== Vaultwarden config ==="
        jq -r '{smtp_host,smtp_port,smtp_security,smtp_from,smtp_from_name,smtp_username,smtp_password:(if .smtp_password then "<configurata>" else "<non configurata>" end)}' "$VW_CONFIG"
    fi
}

install_mail() {
    ensure_env
    configure_nextcloud_now
    configure_vaultwarden_config
    show_status
}

usage() {
    cat <<USAGE
Uso: $0 {install|status}

install  Normalizza SMTP condiviso in .env e applica Nextcloud/Vaultwarden
status   Mostra configurazione SMTP senza stampare password
USAGE
}

require_root
case "${1:-install}" in
    install) install_mail ;;
    status) show_status ;;
    *) usage; exit 1 ;;
esac