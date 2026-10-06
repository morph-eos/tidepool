#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# SETUP NGINX TLS ECDSA — makes TLS 1.2 really usable on all vhosts
# =============================================================================
# The Let's Encrypt certificate shared by all vhosts is ECDSA (prime256v1),
# not RSA. However, the ssl_ciphers lists configured on almost all vhosts
# contained ONLY "ECDHE-RSA-*"/"DHE-RSA-*"/AES*-SHA* suites (none requires
# an ECDSA certificate), so even with ssl_protocols listing TLSv1.2,
# no cipher was ever really negotiable for that certificate: any
# TLS1.2-only client (Android <10, players that use the system TLS such as
# ExoPlayer/DAVx5-OAuth) fails the handshake, while TLS1.3 works because
# there the signature is negotiated separately from the cipher suite.
# Confirmed: the `modem` vhost, which do NOT override ssl_ciphers with
# that list (they use the nginx defaults or "HIGH:!aNULL:!MD5"), negotiate TLS1.2
# without problems with ECDHE-ECDSA-AES256-GCM-SHA384.
#
# Fix: add the equivalent ECDHE-ECDSA-* suites in front of the
# existing lists (kept as an RSA fallback in case the certificate changes in the future).
# =============================================================================

NGINX_CONF="/mnt/nas2/docker/data/nginx/nginx.conf"
NGINX_CONTAINER="nginx"

ECDSA_CIPHERS="ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-SHA256:ECDHE-ECDSA-AES256-SHA384"

log() { echo "[nginx-tls-ecdsa] $*"; }
die() { echo "[nginx-tls-ecdsa] ERRORE: $*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Esegui come root: sudo $0"
}

backup_conf() {
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    cp -p "$NGINX_CONF" "${NGINX_CONF}.bak.${ts}"
    log "Backup: ${NGINX_CONF}.bak.${ts}"
}

needs_patch() {
    ! grep -q "ECDHE-ECDSA-AES256-GCM-SHA384" "$NGINX_CONF"
}

patch_ciphers() {
    python3 - "$NGINX_CONF" "$ECDSA_CIPHERS" <<'PYEOF'
import sys
path, ecdsa = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()

targets = [
    "ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;",
    "ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA:ECDHE-RSA-AES128-SHA:DHE-RSA-AES256-SHA256:DHE-RSA-AES128-SHA256:DHE-RSA-AES256-SHA:DHE-RSA-AES128-SHA:AES256-GCM-SHA384:AES128-GCM-SHA256:AES256-SHA256:AES128-SHA256:AES256-SHA:AES128-SHA:DES-CBC3-SHA;",
]
total = 0
for t in targets:
    if t not in content:
        continue
    replacement = ecdsa + ":" + t
    count = content.count(t)
    content = content.replace(t, replacement)
    total += count

if total == 0:
    sys.exit("nessuna occorrenza delle liste cifrari note trovata, controllo manuale necessario")

with open(path, "w") as f:
    f.write(content)
print(f"Patchate {total} occorrenze")
PYEOF
}

nginx_test_and_reload() {
    log "Verifico sintassi nginx..."
    docker exec "$NGINX_CONTAINER" nginx -t || die "nginx -t fallito, controlla $NGINX_CONF"
    log "Reload nginx..."
    docker exec "$NGINX_CONTAINER" nginx -s reload
}

show_status() {
    log "--- vhost con suite ECDSA ---"
    grep -c "ECDHE-ECDSA-AES256-GCM-SHA384" "$NGINX_CONF" || true
    log "--- test TLS1.2 su alcuni vhost (deve negoziare un cifrario, non 0000) ---"
    docker ps --format '{{.Names}}' | grep -qx "$NGINX_CONTAINER" || { log "Container $NGINX_CONTAINER non attivo"; return; }
    for h in jellyfin.REDACTED_DOMAIN cloud.REDACTED_DOMAIN immich.REDACTED_DOMAIN; do
        local out
        out=$(docker exec "$NGINX_CONTAINER" sh -c "echo | openssl s_client -connect 127.0.0.1:443 -servername $h -tls1_2 2>&1" | grep "Cipher    :" || true)
        log "$h -> $out"
    done
}

install_ecdsa() {
    docker ps --format '{{.Names}}' | grep -qx "$NGINX_CONTAINER" || die "Container $NGINX_CONTAINER non attivo"
    [ -f "$NGINX_CONF" ] || die "nginx.conf non trovato: $NGINX_CONF"

    if needs_patch; then
        backup_conf
        patch_ciphers
        nginx_test_and_reload
    else
        log "Nessuna modifica necessaria (gia' applicato)."
    fi
    show_status
}

usage() {
    cat <<USAGE
Uso: $0 {install|status}

install  Aggiunge le suite ECDHE-ECDSA-* alle liste ssl_ciphers che ne sono
         prive, cosi' TLS1.2 torna negoziabile col certificato ECDSA
         condiviso. Idempotente.
status   Mostra lo stato corrente (conteggio vhost patchati + test live).
USAGE
}

require_root

case "${1:-install}" in
    install) install_ecdsa ;;
    status) show_status ;;
    *) usage; exit 1 ;;
esac
