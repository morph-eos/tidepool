#!/bin/bash

# ============================================================================
# DEPLOY SCRIPT - REDACTED_HOSTNAME_TC Cloud Platform
# ============================================================================
# Script intelligente:
# - Se non ci sono certificati SSL → kickstart per ottenerli
# - Se i certificati esistono → avvia lo stack completo
# - Crea tutte le directory necessarie
# - Verifica servizi dopo l'avvio
#
# Usage: ./deploy.sh
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info()    { echo -e "${BLUE}ℹ${NC} $1"; }
print_success() { echo -e "${GREEN}✅${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_error()   { echo -e "${RED}❌${NC} $1"; }

echo "🚀 REDACTED_HOSTNAME_TC Cloud Platform - Deploy Script"
echo "=============================================="

# Verifica prerequisiti
if [ ! -f "docker-compose.yml" ]; then
    print_error "docker-compose.yml non trovato. Esegui dalla directory /mnt/nas2/docker/"
    exit 1
fi

if [ ! -f ".env" ]; then
    print_error "File .env non trovato!"
    print_info "Copia e configura: cp .env.example .env"
    exit 1
fi

print_info "Caricamento configurazione..."
set -a; source .env; set +a

# Validazione
if [ -z "$EMAIL" ] || [ "$EMAIL" = "tua-email@example.com" ]; then
    print_error "Configura una EMAIL valida nel file .env (necessaria per Let's Encrypt)"
    exit 1
fi

if [ -z "$IMMICH_DB_PASSWORD" ] || [ "$IMMICH_DB_PASSWORD" = "CAMBIA_QUESTA_PASSWORD_IMMICH" ]; then
    print_error "Configura una IMMICH_DB_PASSWORD sicura nel file .env"
    exit 1
fi

print_success "Configurazione validata!"

# === Directory dati ===
print_info "Creazione directory dati..."
mkdir -p data/certbot/{conf,www}
mkdir -p data/nginx/htpasswd
mkdir -p data/immich/{library,postgres}
mkdir -p data/jellyfin/{config,cache}
mkdir -p data/plex/config
mkdir -p data/vaultwarden
mkdir -p data/webdav
mkdir -p data/radicale
mkdir -p data/syncthing
mkdir -p data/openclaw
mkdir -p data/icloud-photos
mkdir -p scripts
print_success "Directory create!"

# === Certificati SSL ===
CERT_PATH="data/certbot/conf/live/REDACTED_HOSTNAME.REDACTED_DDNS/fullchain.pem"

if [ ! -f "$CERT_PATH" ]; then
    print_warning "Certificati SSL non trovati. Avvio kickstart..."
    
    print_info "Verifica che TUTTI questi domini puntino al tuo server:"
    echo "  REDACTED_HOSTNAME.REDACTED_DDNS + www/immich/jellyfin/plex/bitwarden/webdav/syncthing/openclaw/modem"
    echo "  REDACTED_DOMAIN + www/immich/jellyfin/plex/bitwarden/webdav/syncthing/openclaw/modem"
    echo ""
    
    docker compose -f kickstart/docker-compose.yaml up -d nginx
    sleep 5
    
    if ! curl -f -s http://localhost > /dev/null 2>&1; then
        print_error "Nginx kickstart non risponde."
        exit 1
    fi
    
    if docker compose -f kickstart/docker-compose.yaml run --rm certbot; then
        print_success "Certificati SSL ottenuti!"
    else
        print_error "Errore generazione certificati (domini non puntano? porta 80 bloccata? rate limit?)"
        exit 1
    fi
    
    docker compose -f kickstart/docker-compose.yaml down
else
    print_success "Certificati SSL esistenti trovati"
fi

# === Avvio stack ===
print_info "Avvio stack completo..."
docker compose up -d

print_info "Attendo avvio servizi..."
sleep 10

# === Verifica servizi ===
print_info "Verifica servizi..."

check_service() {
    local name="$1" url="$2"
    if curl -f -s -o /dev/null --max-time 5 "$url" 2>/dev/null; then
        print_success "$name operativo"
    else
        print_warning "$name non ancora pronto (potrebbe servire più tempo)"
    fi
}

check_service "Nginx"    "http://localhost:80"
check_service "Immich"   "http://localhost:2283"
check_service "Jellyfin" "http://localhost:8096"

echo ""
print_success "🎉 Deploy completato!"
echo ""
echo "🌐 Servizi attivi:"
echo "  • https://REDACTED_HOSTNAME.REDACTED_DDNS (sito principale)"
echo "  • https://immich.REDACTED_HOSTNAME.REDACTED_DDNS (foto)"
echo "  • https://jellyfin.REDACTED_HOSTNAME.REDACTED_DDNS (media)"
echo "  • https://bitwarden.REDACTED_HOSTNAME.REDACTED_DDNS (password manager)"
echo "  • https://webdav.REDACTED_HOSTNAME.REDACTED_DDNS (file sharing)"
echo "  • https://syncthing.REDACTED_HOSTNAME.REDACTED_DDNS (sync)"
echo "  • https://modem.REDACTED_HOSTNAME.REDACTED_DDNS (modem admin, auth required)"
echo ""
echo "🔌 Servizi opzionali (via profiles):"
echo "  • Plex: docker compose --profile plex up -d"
echo "  • JellyPlex-Watched: docker compose --profile jellyplex up -d"
echo "  • iCloud Sync: docker compose --profile icloud up -d"
echo ""
echo "📊 Monitoraggio: docker compose ps | docker compose logs -f [servizio]"
