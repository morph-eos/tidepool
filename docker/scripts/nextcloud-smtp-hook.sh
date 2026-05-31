#!/usr/bin/env bash
set -eu

OCC="/var/www/html/occ"

log() { echo "[nextcloud-smtp-hook] $*"; }

config_set() {
    php "$OCC" config:system:set "$1" --value="$2" >/dev/null
}

derive_from_address() {
    case "${SMTP_NAME:-}" in
        *@*) printf '%s' "${SMTP_NAME%@*}" ;;
        *) printf 'nextcloud' ;;
    esac
}

derive_domain() {
    case "${SMTP_NAME:-}" in
        *@*) printf '%s' "${SMTP_NAME#*@}" ;;
        *) printf 'localhost' ;;
    esac
}

[ -f "$OCC" ] || exit 0
[ -n "${SMTP_HOST:-}" ] || {
    log "SMTP_HOST non impostato; salto configurazione mail"
    exit 0
}

SMTP_PORT="${SMTP_PORT:-25}"
SMTP_SECURE="${SMTP_SECURE:-}"
SMTP_AUTHTYPE="${SMTP_AUTHTYPE:-LOGIN}"
MAIL_FROM_ADDRESS="${MAIL_FROM_ADDRESS:-$(derive_from_address)}"
MAIL_DOMAIN="${MAIL_DOMAIN:-$(derive_domain)}"

if [ -n "${SMTP_NAME:-}" ] || [ -n "${SMTP_PASSWORD:-}" ]; then
    SMTP_AUTH=1
else
    SMTP_AUTH=0
fi

log "Applico configurazione SMTP da variabili Docker Compose"
config_set mail_smtpmode smtp
config_set mail_smtphost "$SMTP_HOST"
config_set mail_smtpport "$SMTP_PORT"
config_set mail_smtpsecure "$SMTP_SECURE"
config_set mail_smtpauth "$SMTP_AUTH"
config_set mail_smtpauthtype "$SMTP_AUTHTYPE"
config_set mail_smtpname "${SMTP_NAME:-}"

if [ -n "${SMTP_PASSWORD:-}" ]; then
    config_set mail_smtppassword "$SMTP_PASSWORD"
fi

config_set mail_from_address "$MAIL_FROM_ADDRESS"
config_set mail_domain "$MAIL_DOMAIN"
log "Configurazione SMTP applicata"