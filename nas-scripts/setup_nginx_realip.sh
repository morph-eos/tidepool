#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# SETUP NGINX REAL-IP — propaga l'IP client reale attraverso il router SNI
# =============================================================================
# nginx smista tutto l'HTTPS in ingresso su 443 con un blocco `stream`
# (ssl_preread sul SNI) che fa da hairpin verso 127.0.0.1:8442, dove vivono
# i vhost http reali (Nextcloud, Immich, Jellyfin, Plex, Vaultwarden, WebDAV,
# Syncthing, REDACTED_NAME, modem). Quell'hairpin e' una NUOVA connessione TCP
# aperta da nginx verso se stesso: senza PROXY protocol, ogni vhost su 8442
# vede sempre $remote_addr=127.0.0.1, quindi X-Real-IP/X-Forwarded-For inviati
# ai container sono sempre 127.0.0.1 — bruteforce-protection, log e
# rate-limit per-IP (es. Nextcloud) finiscono condivisi da TUTTI i client.
#
# Fix: abilitiamo PROXY protocol sull'hop stream->8442 e lo accettiamo sui
# listener 8442 con ngx_http_realip_module. incus.REDACTED_DOMAIN condivide lo
# stesso proxy_pass ma NON supporta PROXY protocol (romperebbe l'mTLS): gli
# aggiungiamo un piccolo hop interno dedicato (127.0.0.1:18443) che accetta
# e RIMUOVE l'header PROXY protocol prima di inoltrare il TLS/mTLS originale
# intatto verso Incus, cosi' quel percorso resta bit-per-bit invariato.
#
# Poi allineiamo Nextcloud (trusted_proxies + forwarded_for_headers) cosi'
# da fidarsi dell'header e usare l'IP reale per bruteforce-protection e log.
# =============================================================================

NGINX_CONF="/mnt/nas2/docker/data/nginx/nginx.conf"
NGINX_CONTAINER="nginx"
NC_CONTAINER="nextcloud"
NC_TRUSTED_PROXIES_CIDR="172.18.0.0/16"   # subnet docker_default (IP nginx/nextcloud cambiano, la subnet no)

log() { echo "[nginx-realip] $*"; }
die() { echo "[nginx-realip] ERRORE: $*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Esegui come root: sudo $0"
}

backup_conf() {
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    cp -p "$NGINX_CONF" "${NGINX_CONF}.bak.${ts}"
    log "Backup: ${NGINX_CONF}.bak.${ts}"
}

patch_realip_header() {
    if grep -q '^\s*real_ip_header proxy_protocol;' "$NGINX_CONF"; then
        return 1
    fi
    sed -i 's/^\(\s*\)real_ip_header X-Forwarded-For;/\1real_ip_header proxy_protocol;/' "$NGINX_CONF"
    grep -q 'set_real_ip_from 127.0.0.1;' "$NGINX_CONF" || \
        sed -i '/set_real_ip_from 10\.0\.0\.0\/8;/a\    set_real_ip_from 127.0.0.1;' "$NGINX_CONF"
    return 0
}

patch_listen_8442() {
    if grep -q 'listen 8442 ssl http2 proxy_protocol;' "$NGINX_CONF" || \
       grep -q 'listen 8442 ssl proxy_protocol;' "$NGINX_CONF"; then
        return 1
    fi
    sed -i 's/listen 8442 ssl http2;/listen 8442 ssl http2 proxy_protocol;/g' "$NGINX_CONF"
    sed -i 's/listen 8442 ssl;/listen 8442 ssl proxy_protocol;/g' "$NGINX_CONF"
    return 0
}

patch_stream_block() {
    if grep -q '127.0.0.1:18443' "$NGINX_CONF"; then
        return 1
    fi
    python3 - "$NGINX_CONF" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

old_map = "        incus.REDACTED_DOMAIN  172.17.0.1:8443;\n        default            127.0.0.1:8442;\n"
new_map = "        incus.REDACTED_DOMAIN  127.0.0.1:18443;\n        default            127.0.0.1:8442;\n"
if old_map not in content:
    sys.exit("marker mappa stream non trovato, controllo manuale necessario")
content = content.replace(old_map, new_map, 1)

old_server = (
    "    server {\n"
    "        listen 443;\n"
    "        ssl_preread on;\n"
    "        proxy_pass $upstream_443;\n"
    "    }\n"
    "}\n"
)
new_server = (
    "    server {\n"
    "        listen 443;\n"
    "        ssl_preread on;\n"
    "        proxy_pass $upstream_443;\n"
    "        proxy_protocol on;\n"
    "    }\n"
    "\n"
    "    # Incus non supporta PROXY protocol: hop interno che lo rimuove prima\n"
    "    # di inoltrare il TLS/mTLS originale intatto verso Incus.\n"
    "    server {\n"
    "        listen 127.0.0.1:18443 proxy_protocol;\n"
    "        proxy_pass 172.17.0.1:8443;\n"
    "    }\n"
    "}\n"
)
if old_server not in content:
    sys.exit("marker server stream non trovato, controllo manuale necessario")
content = content.replace(old_server, new_server, 1)

with open(path, "w") as f:
    f.write(content)
PYEOF
    return 0
}

nginx_test_and_reload() {
    log "Verifico sintassi nginx..."
    docker exec "$NGINX_CONTAINER" nginx -t || die "nginx -t fallito, controlla $NGINX_CONF"
    log "Reload nginx..."
    docker exec "$NGINX_CONTAINER" nginx -s reload
}

configure_nextcloud() {
    docker ps --format '{{.Names}}' | grep -qx "$NC_CONTAINER" || { log "Container $NC_CONTAINER non attivo, salto config Nextcloud"; return; }
    log "Configuro trusted_proxies/forwarded_for_headers su Nextcloud..."
    docker exec -u www-data "$NC_CONTAINER" php occ config:system:set trusted_proxies 0 --value="$NC_TRUSTED_PROXIES_CIDR"
    docker exec -u www-data "$NC_CONTAINER" php occ config:system:set forwarded_for_headers 0 --value="HTTP_X_FORWARDED_FOR"
}

needs_patch() {
    ! grep -q '^\s*real_ip_header proxy_protocol;' "$NGINX_CONF" || \
    ! { grep -q 'listen 8442 ssl http2 proxy_protocol;' "$NGINX_CONF" || \
        grep -q 'listen 8442 ssl proxy_protocol;' "$NGINX_CONF"; } || \
    ! grep -q '127.0.0.1:18443' "$NGINX_CONF"
}

install_realip() {
    docker ps --format '{{.Names}}' | grep -qx "$NGINX_CONTAINER" || die "Container $NGINX_CONTAINER non attivo"
    [ -f "$NGINX_CONF" ] || die "nginx.conf non trovato: $NGINX_CONF"

    if needs_patch; then
        backup_conf
    else
        log "Nessuna modifica necessaria (gia' applicato)."
    fi

    local changed=0
    if patch_realip_header; then changed=1; fi
    if patch_listen_8442; then changed=1; fi
    if patch_stream_block; then changed=1; fi

    if [ "$changed" -eq 1 ]; then
        nginx_test_and_reload
    fi

    configure_nextcloud
    show_status
}

show_status() {
    log "--- listen 8442 ---"
    grep -n 'listen 8442' "$NGINX_CONF" || true
    log "--- real_ip ---"
    grep -n 'real_ip_header\|set_real_ip_from 127.0.0.1' "$NGINX_CONF" || true
    log "--- stream block ---"
    sed -n '/^stream {/,/^}/p' "$NGINX_CONF"
    log "--- nginx -t ---"
    docker exec "$NGINX_CONTAINER" nginx -t 2>&1 || true
    if docker ps --format '{{.Names}}' | grep -qx "$NC_CONTAINER"; then
        log "--- Nextcloud trusted_proxies/forwarded_for_headers ---"
        docker exec -u www-data "$NC_CONTAINER" php occ config:system:get trusted_proxies 2>&1 || true
        docker exec -u www-data "$NC_CONTAINER" php occ config:system:get forwarded_for_headers 2>&1 || true
    fi
}

usage() {
    cat <<USAGE
Uso: $0 {install|status}

install  Abilita PROXY protocol sull'hop interno stream->8442 (con relay
         dedicato che lo rimuove prima di Incus), configura real_ip e
         trusted_proxies/forwarded_for_headers su Nextcloud. Idempotente.
status   Mostra lo stato corrente della config.
USAGE
}

require_root

case "${1:-install}" in
    install) install_realip ;;
    status) show_status ;;
    *) usage; exit 1 ;;
esac
