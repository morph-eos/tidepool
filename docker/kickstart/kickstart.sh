#!/bin/bash

# ============================================================================
# KICKSTART SCRIPT - REDACTED_HOSTNAME_TC Cloud Platform
# ============================================================================
# Bootstrap da zero:
# 1. Valida env
# 2. Crea directory
# 3. Configura regole udev per device stabili
# 4. Ottiene certificati SSL via kickstart compose
# 5. Deploya lo stack completo
# 6. Configura UFW, Avahi
#
# Usage: ./kickstart/kickstart.sh
# Prerequisiti: Docker, docker-compose, .env configurato
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

echo "🚀 REDACTED_HOSTNAME_TC Cloud Platform — Kickstart"
echo "========================================"

# === .env ===
if [ ! -f ".env" ]; then
    print_error ".env non trovato!"
    print_info "cp .env.example .env && nano .env"
    exit 1
fi

set -a; source .env; set +a

if [ -z "$EMAIL" ] || [ "$EMAIL" = "tua-email@example.com" ] || [ "$EMAIL" = "your-email@example.com" ]; then
    print_error "Configura EMAIL in .env (necessaria per Let's Encrypt)"
    exit 1
fi

if [ -z "$IMMICH_DB_PASSWORD" ] || [ "$IMMICH_DB_PASSWORD" = "CAMBIA_QUESTA_PASSWORD_IMMICH" ]; then
    print_error "Configura IMMICH_DB_PASSWORD in .env"
    exit 1
fi

print_success "Configurazione validata"

# === Directory ===
print_info "Creazione directory dati..."
mkdir -p data/certbot/{conf,www}
mkdir -p data/nginx/htpasswd
mkdir -p data/immich/{library,postgres,backups}
mkdir -p data/jellyfin/{config,cache}
mkdir -p data/plex/config
mkdir -p data/vaultwarden
mkdir -p data/webdav
mkdir -p data/radicale
mkdir -p data/syncthing
mkdir -p data/openclaw
mkdir -p data/icloud-photos
mkdir -p scripts
print_success "Directory create"

# === Regole udev ===
UDEV_FILE="/etc/udev/rules.d/99-smartcheck-disks.rules"
if [ ! -f "$UDEV_FILE" ]; then
    print_info "Creazione regole udev per symlink dischi stabili..."
    sudo tee "$UDEV_FILE" > /dev/null << 'UDEV'
# NAS2 (USB, serial REDACTED_DISK_SERIAL)
SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ENV{ID_SERIAL_SHORT}=="REDACTED_DISK_SERIAL", SYMLINK+="smartcheck-nas2"
# NAS (SATA, serial REDACTED_DISK_SERIAL)
SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ENV{ID_SERIAL_SHORT}=="REDACTED_DISK_SERIAL", SYMLINK+="smartcheck-nas"
UDEV
    sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=block
    print_success "Regole udev create"
else
    print_success "Regole udev già presenti"
fi

# === UFW ===
print_info "Configurazione UFW..."
LAN_SUBNET="192.0.2.0/24"
sudo ufw --force enable
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Regole idempotenti (ufw ignora duplicati)
sudo ufw allow 2222/tcp comment "SSH + VSCode Remote" 2>/dev/null || true
sudo ufw allow 80/tcp comment "HTTP nginx" 2>/dev/null || true
sudo ufw allow 443/tcp comment "HTTPS nginx" 2>/dev/null || true
sudo ufw allow 22000/tcp comment "Syncthing sync" 2>/dev/null || true
sudo ufw allow 22000/udp comment "Syncthing sync" 2>/dev/null || true
sudo ufw allow from "$LAN_SUBNET" to any port 139 proto tcp comment "Samba LAN only" 2>/dev/null || true
sudo ufw allow from "$LAN_SUBNET" to any port 445 proto tcp comment "Samba LAN only" 2>/dev/null || true
sudo ufw allow from "$LAN_SUBNET" to any port 21027 proto udp comment "Syncthing discovery LAN" 2>/dev/null || true
# Rimuovi regole Samba generiche se presenti
sudo ufw delete allow Samba 2>/dev/null || true
sudo ufw delete allow samba 2>/dev/null || true
print_success "UFW configurato"

# === Avahi (LAN only) ===
LAN_INTERFACE="REDACTED_NIC_NAME"
if command -v avahi-daemon &>/dev/null; then
    print_info "Configurazione Avahi (ristretto a $LAN_INTERFACE)..."
    sudo tee /etc/avahi/avahi-daemon.conf > /dev/null << AVAHI
[server]
use-ipv4=yes
allow-interfaces=$LAN_INTERFACE
use-ipv6=yes
ratelimit-interval-usec=1000000
ratelimit-burst=1000

[wide-area]
enable-wide-area=yes

[publish]
publish-hinfo=no
publish-workstation=no

[reflector]

[rlimits]
AVAHI
    sudo systemctl restart avahi-daemon
    print_success "Avahi configurato"
fi

# === Disabilita CUPS (non necessario) ===
for svc in cups cups-browsed cups.socket; do
    sudo systemctl disable --now "$svc" 2>/dev/null || true
done

# === Certificati SSL ===
CERT_PATH="data/certbot/conf/live/REDACTED_HOSTNAME.REDACTED_DDNS/fullchain.pem"

if [ ! -f "$CERT_PATH" ]; then
    print_warning "Certificati SSL non trovati. Avvio kickstart..."
    
    print_info "Verifica che TUTTI questi domini puntino a questo server:"
    echo "  REDACTED_HOSTNAME.REDACTED_DDNS + sottodomini: immich, jellyfin, plex, bitwarden, webdav, radicale, syncthing, openclaw, modem"
    echo "  REDACTED_DOMAIN + stessi sottodomini"
    echo ""
    
    # Crea il volume named se non esiste (bootstrap da zero)
    if ! docker volume inspect docker_certbot-www &>/dev/null; then
        print_info "Creazione volume docker_certbot-www..."
        docker volume create docker_certbot-www
    fi
    
    docker-compose -f kickstart/docker-compose.yaml up -d nginx
    sleep 5
    
    if ! curl -f -s http://localhost > /dev/null 2>&1; then
        print_error "Nginx kickstart non risponde"
        docker-compose -f kickstart/docker-compose.yaml logs nginx
        exit 1
    fi
    
    if docker-compose -f kickstart/docker-compose.yaml run --rm certbot; then
        print_success "Certificati ottenuti!"
    else
        print_error "Errore generazione certificati"
        docker-compose -f kickstart/docker-compose.yaml logs
        exit 1
    fi
    
    docker-compose -f kickstart/docker-compose.yaml down
else
    print_success "Certificati SSL esistenti"
fi

# === Deploy stack ===
print_info "Avvio stack completo..."
docker-compose up -d
sleep 10

# === Verifica ===
print_info "Verifica servizi..."
for svc_url in "Nginx:http://localhost:80" "Immich:http://localhost:2283" "Jellyfin:http://localhost:8096"; do
    name=${svc_url%%:*}
    url=${svc_url#*:}
    if curl -f -s -o /dev/null --max-time 5 "$url" 2>/dev/null; then
        print_success "$name operativo"
    else
        print_warning "$name non ancora pronto"
    fi
done

echo ""
print_success "🎉 Kickstart completato!"
echo ""
echo "🌐 Servizi: https://REDACTED_HOSTNAME.REDACTED_DDNS"
echo "📊 Stato:   cd /mnt/nas2/docker && ./utils.sh status"
echo "📝 Help:    /mnt/nas2/nas-scripts/nas-help.sh"
