#!/bin/bash

# ============================================================================
# SYSTEM CHECK - REDACTED_HOSTNAME_TC Cloud Platform
# ============================================================================
# 
# Script di verifica per controllare che tutto sia configurato correttamente
# prima del deployment. Installa automaticamente i pacchetti mancanti su Ubuntu.
#
# Usage: ./check.sh [--install]
#        --install: Installa automaticamente i pacchetti mancanti
# ============================================================================

set -e

# Colori
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${BLUE}ℹ${NC} $1"; }
print_success() { echo -e "${GREEN}✅${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_error() { echo -e "${RED}❌${NC} $1"; }

# Controlla se il flag --install è stato passato
AUTO_INSTALL=false
if [ "$1" = "--install" ]; then
    AUTO_INSTALL=true
    print_info "Modalità auto-install attivata"
fi

# Funzione per installare pacchetti mancanti
install_package() {
    local package=$1
    local description=$2
    
    if [ "$AUTO_INSTALL" = true ]; then
        print_info "Installazione $description..."
        sudo apt update
        sudo apt install -y $package
        return 0
    else
        print_warning "Per installare automaticamente, riavvia con: ./check.sh --install"
        print_info "Oppure installa manualmente: sudo apt install $package"
        return 1
    fi
}

echo "🔍 REDACTED_HOSTNAME_TC Cloud Platform - System Check"
echo "==========================================="

ERRORS=0

# Verifica Docker
print_info "Controllo Docker..."
if command -v docker > /dev/null 2>&1; then
    if docker info > /dev/null 2>&1; then
        DOCKER_VERSION=$(docker --version | cut -d' ' -f3 | cut -d',' -f1)
        print_success "Docker operativo (versione: $DOCKER_VERSION)"
    else
        print_error "Docker installato ma non operativo"
        print_info "Prova: sudo systemctl start docker"
        print_info "Per avviare automaticamente: sudo systemctl enable docker"
        ((ERRORS++))
    fi
else
    print_error "Docker non installato"
    if install_package "docker.io" "Docker"; then
        print_info "Configurazione Docker post-installazione..."
        sudo systemctl start docker
        sudo systemctl enable docker
        sudo usermod -aG docker $USER
        print_warning "IMPORTANTE: Riavvia la sessione o esegui 'newgrp docker' per applicare i permessi di gruppo"
        print_success "Docker installato con successo!"
    else
        ((ERRORS++))
    fi
fi

# Verifica Docker Compose
print_info "Controllo Docker Compose..."
if command -v docker-compose > /dev/null 2>&1; then
    COMPOSE_VERSION=$(docker-compose --version | cut -d' ' -f4 | cut -d',' -f1)
    print_success "Docker Compose operativo (versione: $COMPOSE_VERSION)"
else
    print_error "Docker Compose non installato"
    if install_package "docker-compose" "Docker Compose"; then
        print_success "Docker Compose installato con successo!"
    else
        ((ERRORS++))
    fi
fi

# Verifica file .env
print_info "Controllo configurazione..."
if [ -f ".env" ]; then
    source .env
    
    # Controlla email
    if [ -z "$EMAIL" ] || [ "$EMAIL" = "tua-email@example.com" ]; then
        print_error "EMAIL non configurata nel file .env"
        ((ERRORS++))
    else
        print_success "Email configurata: $EMAIL"
    fi
    
    # Controlla password Immich
    if [ -z "$IMMICH_DB_PASSWORD" ] || [ "$IMMICH_DB_PASSWORD" = "CAMBIA_QUESTA_PASSWORD_IMMICH" ]; then
        print_error "IMMICH_DB_PASSWORD non configurata nel file .env"
        ((ERRORS++))
    else
        print_success "Password Immich configurata"
    fi
    
    # Controlla configurazione Jellyfin
    if [ -z "$JELLYFIN_MEDIA" ] || [ "$JELLYFIN_MEDIA" = "/path/to/your/media" ]; then
        print_warning "JELLYFIN_MEDIA non configurato nel file .env"
        print_info "Configura i percorsi reali dei tuoi file media"
    else
        if [ -d "$JELLYFIN_MEDIA" ]; then
            print_success "Directory media Jellyfin trovata: $JELLYFIN_MEDIA"
        else
            print_warning "Directory media Jellyfin non trovata: $JELLYFIN_MEDIA"
            print_info "Assicurati che il percorso sia corretto e accessibile"
        fi
    fi
    
else
    print_error "File .env non trovato"
    print_info "Creazione file .env template..."
    
    # Crea il file .env template automaticamente
    cat > .env << 'EOF'
# REDACTED_HOSTNAME_TC Cloud Platform Environment Variables
# Modifica questi valori con le tue configurazioni

# Email per certificati Let's Encrypt (OBBLIGATORIO)
EMAIL=tua-email@example.com

# Configurazione Immich
IMMICH_VERSION=release
IMMICH_TZ=Europe/Rome
IMMICH_DATA=./data/immich/library
IMMICH_DB_DATA=./data/immich/postgres
IMMICH_DB_PASSWORD=CAMBIA_QUESTA_PASSWORD_IMMICH
IMMICH_DB_USERNAME=immich
IMMICH_DB_DATABASE_NAME=immich

# Configurazione Jellyfin (Media Server)
JELLYFIN_TZ=Europe/Rome
JELLYFIN_UID=1000
JELLYFIN_GID=1000
JELLYFIN_PORT=8096
JELLYFIN_CONFIG=./data/jellyfin/config
JELLYFIN_CACHE=./data/jellyfin/cache
JELLYFIN_MEDIA=/mnt/nas2/media
JELLYFIN_MEDIA2=/mnt/nas2/media
JELLYFIN_MEDIA_READONLY=true
JELLYFIN_FONTS=/usr/share/fonts
EOF
    
    print_success "File .env creato! MODIFICA I VALORI prima di continuare:"
    print_warning "- Imposta una EMAIL valida per i certificati SSL"
    print_warning "- Cambia le PASSWORD con valori sicuri"
    print_info "Riavvia questo script dopo aver modificato .env"
    ((ERRORS++))
fi

# Verifica file necessari
print_info "Controllo file configurazione..."
for file in "docker-compose.yml" "data/nginx/nginx.conf" "kickstart/docker-compose.yaml" "kickstart/nginx.conf"; do
    if [ -f "$file" ]; then
        print_success "File presente: $file"
    else
        print_error "File mancante: $file"
        ((ERRORS++))
    fi
done

# Verifica script
print_info "Controllo script..."
for script in "deploy.sh" "utils.sh"; do
    if [ -f "$script" ] && [ -x "$script" ]; then
        print_success "Script pronto: $script"
    else
        print_warning "Script non eseguibile: $script (chmod +x $script)"
    fi
done

# Verifica e installa strumenti aggiuntivi
print_info "Controllo strumenti aggiuntivi..."

# Verifica curl
if ! command -v curl > /dev/null 2>&1; then
    print_warning "curl non installato"
    if install_package "curl" "curl"; then
        print_success "curl installato con successo!"
    fi
fi

# Verifica netstat
if ! command -v netstat > /dev/null 2>&1; then
    print_warning "netstat non installato"
    if install_package "net-tools" "net-tools (netstat)"; then
        print_success "net-tools installato con successo!"
    fi
fi

# Verifica nslookup
if ! command -v nslookup > /dev/null 2>&1; then
    print_warning "nslookup non installato"
    if install_package "dnsutils" "dnsutils (nslookup)"; then
        print_success "dnsutils installato con successo!"
    fi
fi


# Verifica regole udev per dischi
print_info "Controllo regole udev..."
UDEV_FILE="/etc/udev/rules.d/99-smartcheck-disks.rules"
if [ -f "" ]; then
    print_success "Regole udev presenti: "
    if [ -e /dev/smartcheck-nas ] && [ -e /dev/smartcheck-nas2 ]; then
        print_success "Symlink dischi attivi: /dev/smartcheck-nas, /dev/smartcheck-nas2"
    else
        print_warning "Symlink dischi non attivi (udevadm trigger necessario?)"
    fi
else
    print_warning "Regole udev non trovate () — esegui kickstart o setup_disk.sh"
fi

# Verifica UFW
print_info "Controllo UFW..."
if command -v ufw > /dev/null 2>&1; then
    if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        print_success "UFW attivo"
    else
        print_warning "UFW installato ma inattivo"
    fi
else
    print_warning "UFW non installato"
fi

# Verifica Avahi
print_info "Controllo Avahi..."
if systemctl is-active avahi-daemon &>/dev/null; then
    if grep -q "allow-interfaces" /etc/avahi/avahi-daemon.conf 2>/dev/null; then
        print_success "Avahi attivo (ristretto a interfaccia LAN)"
    else
        print_warning "Avahi attivo ma NON ristretto a interfaccia LAN"
    fi
else
    print_info "Avahi non attivo"
fi

# Verifica porte
print_info "Controllo porte..."
for port in 80 443; do
    if netstat -tuln 2>/dev/null | grep ":$port " > /dev/null; then
        print_warning "Porta $port già in uso (potrebbe essere normale se nginx è già avviato)"
    else
        print_success "Porta $port disponibile"
    fi
done

# Verifica spazio disco
print_info "Controllo spazio disco..."
DISK_USAGE=$(df . | awk 'NR==2 {print $5}' | sed 's/%//')
if [ "$DISK_USAGE" -gt 90 ]; then
    print_warning "Spazio disco basso: ${DISK_USAGE}% utilizzato"
elif [ "$DISK_USAGE" -gt 80 ]; then
    print_info "Spazio disco: ${DISK_USAGE}% utilizzato"
else
    print_success "Spazio disco: ${DISK_USAGE}% utilizzato"
fi

# Verifica DNS (se possibile)
print_info "Controllo DNS..."
if command -v nslookup > /dev/null 2>&1; then
    for domain in "REDACTED_HOSTNAME.REDACTED_DDNS" "immich.REDACTED_HOSTNAME.REDACTED_DDNS" "jellyfin.REDACTED_HOSTNAME.REDACTED_DDNS" "bitwarden.REDACTED_HOSTNAME.REDACTED_DDNS" "webdav.REDACTED_HOSTNAME.REDACTED_DDNS" "radicale.REDACTED_HOSTNAME.REDACTED_DDNS" "syncthing.REDACTED_HOSTNAME.REDACTED_DDNS" "openclaw.REDACTED_HOSTNAME.REDACTED_DDNS" "modem.REDACTED_HOSTNAME.REDACTED_DDNS" "www.REDACTED_DOMAIN"; do
        if nslookup "$domain" > /dev/null 2>&1; then
            IP=$(nslookup "$domain" | awk '/^Address: / { print $2 }' | tail -1)
            print_success "DNS risolve: $domain → $IP"
        else
            print_warning "DNS non risolve: $domain (configurare prima del deploy)"
        fi
    done
else
    print_info "nslookup non disponibile, skip controllo DNS"
fi

echo ""
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    print_success "🎉 Tutti i controlli superati! Sistema pronto per il deploy."
    echo ""
    print_info "Prossimi passi:"
    echo "1. Verifica che il file .env sia configurato correttamente"
    echo "2. Configura i record DNS se non già fatto"
    echo "3. Esegui: ./deploy.sh"
    echo "4. Monitora con: ./utils.sh status"
else
    print_error "❌ Trovati $ERRORS errori."
    echo ""
    if [ "$AUTO_INSTALL" = false ]; then
        print_info "💡 Suggerimento: Esegui './check.sh --install' per installare automaticamente i pacchetti mancanti"
    fi
    print_info "Risolvi i problemi evidenziati e riavvia il controllo"
    exit 1
fi
