#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# SETUP JELLYFIN SSO BUTTON — injects a real SSO login button into the
# Jellyfin login page via nginx sub_filter.
# =============================================================================
# Why it is needed: the SSO Authentication plugin (K0lin, 5.x) does not inject a
# button into the Jellyfin web client (a design limit of the plugin, not a
# bug — verified: no configuration field for this in any
# version checked). The only way to sign in via SSO was the
# direct URL /sso/OID/start/nextcloud.
#
# How it works: nginx serves /nc-sso-button.js as a static file and uses
# sub_filter to inject <script src="/nc-sso-button.js"></script> before
# </body> in Jellyfin's HTML response (text/html only, it does not touch
# API/JSON responses or video streaming). The JS script adds a fixed
# button at the bottom right when the page hash is #/login (or
# empty), and removes it elsewhere — polling on location.hash, no dependency
# on Jellyfin's internal CSS classes that might change with an update.
#
# Usage:
#   sudo /mnt/nas2/nas-scripts/setup_jellyfin_sso_button.sh install
#   sudo /mnt/nas2/nas-scripts/setup_jellyfin_sso_button.sh status
# =============================================================================

NGINX_DATA_DIR="/mnt/nas2/docker/data/nginx"
NGINX_CONF="${NGINX_DATA_DIR}/nginx.conf"
JS_SOURCE="${NGINX_DATA_DIR}/nc-sso-button.js"
DOCKER_DIR="/mnt/nas2/docker"

log() { echo "[jellyfin-sso-button] $*"; }
die() { echo "[jellyfin-sso-button] ERRORE: $*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Esegui come root: sudo $0 <install|status>"
}

is_installed() {
    grep -q "nc-sso-button.js" "$NGINX_CONF" 2>/dev/null
}

show_status() {
    [ -f "$JS_SOURCE" ] && log "JS presente: $JS_SOURCE" || log "JS ASSENTE: $JS_SOURCE"
    if is_installed; then
        log "sub_filter/location già presenti in nginx.conf"
    else
        log "sub_filter/location NON presenti in nginx.conf"
    fi
    curl -sk -o /dev/null -w "[jellyfin-sso-button] JS servito via nginx: HTTP %{http_code}\n" \
        --resolve jellyfin.REDACTED_DOMAIN:443:127.0.0.1 https://jellyfin.REDACTED_DOMAIN/nc-sso-button.js || true
}

install() {
    [ -f "$JS_SOURCE" ] || die "Manca $JS_SOURCE — crealo prima di eseguire lo script"

    if is_installed; then
        log "Già installato in nginx.conf, nessuna modifica necessaria"
    else
        local backup="${NGINX_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$NGINX_CONF" "$backup"
        log "Backup nginx.conf: $backup"

        # Inserts the static location for the JS and the sub_filter right after
        # the "location / {" block of the jellyfin vhost (identified by the proxy_pass
        # jellyfin-backend), without touching the other vhosts.
        python3 - "$NGINX_CONF" << 'PYEOF'
import re, sys

path = sys.argv[1]
with open(path) as f:
    content = f.read()

marker = "# Proxy to Jellyfin server\n        location / {"
idx = content.find(marker)
if idx == -1:
    print("ERRORE: marker 'location /' di jellyfin non trovato", file=sys.stderr)
    sys.exit(1)

# Find the closing of the "location / { ... }" block of the jellyfin vhost
brace_start = content.find("{", idx)
depth = 0
i = brace_start
while i < len(content):
    if content[i] == "{":
        depth += 1
    elif content[i] == "}":
        depth -= 1
        if depth == 0:
            break
    i += 1
block_end = i  # index of the closing "}"

sub_filter_block = (
    "\n\n            # SSO button injection (setup_jellyfin_sso_button.sh)\n"
    "            # (sub_filter_types default gia' include text/html, non va ridichiarato)\n"
    "            sub_filter_once on;\n"
    "            sub_filter '</body>' '<script src=\"/nc-sso-button.js\"></script></body>';\n"
)

new_location_block = (
    "\n\n        # Static SSO button script (setup_jellyfin_sso_button.sh)\n"
    "        location = /nc-sso-button.js {\n"
    "            root /etc/nginx;\n"
    "            add_header Cache-Control \"no-cache\" always;\n"
    "        }\n"
)

# Insert the sub_filter right before the closing of the location / block
content = content[:block_end] + sub_filter_block + content[block_end:]
# Insert the new location after the closing of the block (which has shifted by len(sub_filter_block))
insert_point = block_end + len(sub_filter_block) + 1
content = content[:insert_point] + new_location_block + content[insert_point:]

with open(path, "w") as f:
    f.write(content)

print("Patch applicata")
PYEOF
        log "nginx.conf patchato"
    fi

    log "JS già in ${NGINX_DATA_DIR} (root /etc/nginx del container -> servito a /nc-sso-button.js)"

    log "Verifico sintassi nginx..."
    docker exec nginx nginx -t 2>&1 | grep -v "protocol options redefined" || true

    log "Ricarico nginx..."
    docker exec nginx nginx -s reload

    sleep 1
    show_status
}

require_root

case "${1:-status}" in
    install) install ;;
    status) show_status ;;
    *) die "Comando non valido: $1 (install|status)" ;;
esac
