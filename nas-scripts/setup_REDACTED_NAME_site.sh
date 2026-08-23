#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# SETUP REDACTED_NAME SITE — riorganizza REDACTED_NAME.REDACTED_DOMAIN in due sottopagine
# =============================================================================
# REDACTED_NAME.REDACTED_DOMAIN era un unico sito statico (root vhost = index.html), protetto
# da auth_basic a livello di server con /etc/nginx/htpasswd/REDACTED_NAME.
#
# Nuova struttura:
#   /            -> pagina di landing con 2 link, STESSA password del vecchio sito
#   /quotes/     -> vecchio sito (contenuto originale), password invariata
#   /festa-ruolo/ -> "Invito REDACTED_NAME" (ex file standalone in /mnt/nas2), LIBERO
#                    (auth_basic off esplicito sulla location, uniche eccezione
#                    al server-level auth_basic ereditato da tutto il resto)
#
# Idempotente: rieseguibile, la seconda esecuzione e' no-op.
# =============================================================================

NGINX_CONF="/mnt/nas2/docker/data/nginx/nginx.conf"
REDACTED_NAME_DIR="/mnt/nas2/docker/data/nginx/REDACTED_NAME"
QUOTES_DIR="$REDACTED_NAME_DIR/quotes"
FESTA_DIR="$REDACTED_NAME_DIR/festa-ruolo"
INVITO_SOURCE="/mnt/nas2/Invito REDACTED_NAME v2 - standalone.html"
NGINX_CONTAINER="nginx"
OWNER="REDACTED_HOSTNAME:REDACTED_HOSTNAME"

log() { echo "[REDACTED_NAME-site] $*"; }
die() { echo "[REDACTED_NAME-site] ERRORE: $*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Esegui come root: sudo $0"
}

backup_conf() {
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    cp -p "$NGINX_CONF" "${NGINX_CONF}.bak.${ts}"
    log "Backup: ${NGINX_CONF}.bak.${ts}"
}

move_old_site() {
    mkdir -p "$QUOTES_DIR"
    if [ -f "$QUOTES_DIR/index.html" ]; then
        log "Vecchio sito gia' in $QUOTES_DIR/index.html, skip."
        return
    fi
    [ -f "$REDACTED_NAME_DIR/index.html" ] || die "Ne' $REDACTED_NAME_DIR/index.html ne' $QUOTES_DIR/index.html trovati: stato inatteso."
    mv "$REDACTED_NAME_DIR/index.html" "$QUOTES_DIR/index.html"
    log "Vecchio sito spostato in $QUOTES_DIR/index.html"
}

move_invito() {
    mkdir -p "$FESTA_DIR"
    if [ -f "$INVITO_SOURCE" ]; then
        mv "$INVITO_SOURCE" "$FESTA_DIR/index.html"
        log "Invito REDACTED_NAME spostato in $FESTA_DIR/index.html"
    elif [ -f "$FESTA_DIR/index.html" ]; then
        log "Invito REDACTED_NAME gia' in $FESTA_DIR/index.html, skip."
    else
        die "Ne' '$INVITO_SOURCE' ne' $FESTA_DIR/index.html trovati: stato inatteso."
    fi
}

write_landing_page() {
    cat > "$REDACTED_NAME_DIR/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="it">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>REDACTED_NAME ❤️</title>
  <style>
    @import url('https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;700;900&display=swap');

    * { margin: 0; padding: 0; box-sizing: border-box; }

    :root {
      --black: #0a0a0a;
      --white: #f5f0e8;
      --red: #e8003d;
      --yellow: #ffe600;
      --border: 3px solid var(--black);
    }

    body {
      background: var(--white);
      color: var(--black);
      font-family: 'Space Grotesk', sans-serif;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      padding: 2rem;
      overflow-x: hidden;
    }

    .frame {
      border: var(--border);
      box-shadow: 8px 8px 0 var(--black);
      background: var(--white);
      max-width: 680px;
      width: 100%;
      padding: 3rem 2.5rem;
      position: relative;
    }

    .tag {
      position: absolute;
      top: -18px;
      left: 2rem;
      background: var(--yellow);
      border: var(--border);
      font-size: 0.75rem;
      font-weight: 700;
      letter-spacing: 0.15em;
      text-transform: uppercase;
      padding: 2px 10px;
    }

    h1 {
      font-size: clamp(2.8rem, 8vw, 5rem);
      font-weight: 900;
      line-height: 1;
      letter-spacing: -0.03em;
      margin-bottom: 0.5rem;
    }

    h1 span { color: var(--red); }

    .sub {
      font-size: 1rem;
      font-weight: 400;
      color: #555;
      margin-bottom: 2.5rem;
      border-left: 4px solid var(--yellow);
      padding-left: 0.75rem;
    }

    .link-wrap {
      display: flex;
      flex-direction: column;
      gap: 1.25rem;
    }

    .link-btn {
      display: block;
      background: var(--red);
      color: var(--white);
      border: var(--border);
      box-shadow: 5px 5px 0 var(--black);
      font-family: 'Space Grotesk', sans-serif;
      font-size: 1.1rem;
      font-weight: 900;
      letter-spacing: 0.05em;
      text-transform: uppercase;
      text-decoration: none;
      padding: 1.4rem 1.5rem;
      text-align: center;
      transition: transform 0.1s, box-shadow 0.1s;
    }

    .link-btn:hover {
      transform: translate(-2px, -2px);
      box-shadow: 7px 7px 0 var(--black);
    }

    .link-btn:active {
      transform: translate(4px, 4px);
      box-shadow: 1px 1px 0 var(--black);
    }

    .link-btn.secondary {
      background: var(--black);
    }

    .link-btn small {
      display: block;
      font-size: 0.7rem;
      font-weight: 400;
      letter-spacing: 0.1em;
      opacity: 0.8;
      margin-top: 0.3rem;
      text-transform: none;
    }
  </style>
</head>
<body>
  <div class="frame">
    <div class="tag">REDACTED_NAME.REDACTED_DOMAIN</div>
    <h1>Ciao <span>REDACTED_NAME</span> ❤️</h1>
    <p class="sub">Scegli dove andare.</p>
    <div class="link-wrap">
      <a class="link-btn" href="/festa-ruolo/">
        Invito
        <small>la festa a tema</small>
      </a>
      <a class="link-btn secondary" href="/quotes/">
        Vecchio sito
        <small>quotes &amp; company</small>
      </a>
    </div>
  </div>
</body>
</html>
HTML
    log "Landing page scritta in $REDACTED_NAME_DIR/index.html"
}

needs_nginx_patch() {
    ! grep -q "location /festa-ruolo" "$NGINX_CONF"
}

patch_nginx_conf() {
    python3 - "$NGINX_CONF" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

target = """        auth_basic_user_file /etc/nginx/htpasswd/REDACTED_NAME;

        location / {
            try_files $uri $uri/ /index.html;
        }
    }"""

replacement = """        auth_basic_user_file /etc/nginx/htpasswd/REDACTED_NAME;

        location /festa-ruolo {
            auth_basic off;
            try_files $uri $uri/ /festa-ruolo/index.html;
        }

        location / {
            try_files $uri $uri/ /index.html;
        }
    }"""

if target not in content:
    sys.exit("blocco REDACTED_NAME atteso non trovato in nginx.conf, controllo manuale necessario")

count = content.count(target)
if count != 1:
    sys.exit(f"il blocco atteso compare {count} volte (atteso 1), controllo manuale necessario")

content = content.replace(target, replacement)
with open(path, "w") as f:
    f.write(content)
print("nginx.conf patchato: aggiunta location /festa-ruolo senza auth_basic")
PYEOF
}

nginx_test_and_reload() {
    log "Verifico sintassi nginx..."
    docker exec "$NGINX_CONTAINER" nginx -t || die "nginx -t fallito, controlla $NGINX_CONF"
    log "Reload nginx..."
    docker exec "$NGINX_CONTAINER" nginx -s reload
}

fix_perms() {
    chown -R "$OWNER" "$REDACTED_NAME_DIR"
    find "$REDACTED_NAME_DIR" -type d -exec chmod 775 {} +
    find "$REDACTED_NAME_DIR" -type f -exec chmod 664 {} +
}

show_status() {
    log "--- struttura $REDACTED_NAME_DIR ---"
    find "$REDACTED_NAME_DIR" -maxdepth 2 -type f
    log "--- location /festa-ruolo in nginx.conf ---"
    grep -q "location /festa-ruolo" "$NGINX_CONF" && log "presente" || log "ASSENTE"
}

install_REDACTED_NAME_site() {
    docker ps --format '{{.Names}}' | grep -qx "$NGINX_CONTAINER" || die "Container $NGINX_CONTAINER non attivo"
    [ -f "$NGINX_CONF" ] || die "nginx.conf non trovato: $NGINX_CONF"

    move_old_site
    move_invito
    write_landing_page

    if needs_nginx_patch; then
        backup_conf
        patch_nginx_conf
        nginx_test_and_reload
    else
        log "nginx.conf gia' patchato, skip."
    fi

    fix_perms
    show_status
}

usage() {
    cat <<USAGE
Uso: $0 {install|status}

install  Riorganizza REDACTED_NAME.REDACTED_DOMAIN: /quotes (vecchio sito, password),
         /festa-ruolo (Invito REDACTED_NAME, libero), / (landing, password).
         Idempotente.
status   Mostra la struttura corrente e se nginx.conf e' patchato.
USAGE
}

require_root

case "${1:-install}" in
    install) install_REDACTED_NAME_site ;;
    status) show_status ;;
    *) usage; exit 1 ;;
esac
