#!/bin/bash

# ============================================================================
# UTILITY SCRIPT - REDACTED_HOSTNAME_TC Cloud Platform
# ============================================================================
# Operazioni comuni di manutenzione per lo stack Docker.
#
# Usage: ./utils.sh [comando]
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

show_usage() {
    echo "🔧 REDACTED_HOSTNAME_TC Utilities"
    echo ""
    echo "Usage: ./utils.sh [comando]"
    echo ""
    echo "Comandi disponibili:"
    echo "  status       Mostra stato di tutti i servizi"
    echo "  logs         Log in tempo reale (tutti o singolo servizio)"
    echo "  stop         Ferma tutti i servizi"
    echo "  restart      Riavvia tutti i servizi"
    echo "  update       Aggiorna immagini Docker e riavvia"
    echo "  backup       Backup database Immich (PostgreSQL)"
    echo "  renew        Rinnova certificati SSL (usa certbot dal compose)"
    echo "  smartcheck   Forza un check SMART immediato"
    echo "  clean        Pulizia Docker (rimuove immagini inutilizzate)"
    echo "  reset        Reset completo (⚠️  CANCELLA TUTTI I DATI)"
    echo "  sync         Gestione JellyPlex-Watched (profile)"
    echo "  icloud       Gestione sincronizzazione iCloud (profile)"
    echo ""
}

check_env() {
    if [ ! -f ".env" ]; then
        print_error "File .env non trovato!"
        exit 1
    fi
    source .env
}

cmd_status() {
    print_info "Stato servizi Docker Compose:"
    docker compose ps
    echo ""
    
    print_info "Utilizzo risorse:"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" 2>/dev/null | head -20
    echo ""
    
    # Certificati SSL
    CERT_PATH="data/certbot/conf/live/REDACTED_HOSTNAME.REDACTED_DDNS/fullchain.pem"
    if [ -f "$CERT_PATH" ]; then
        EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)
        EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s)
        CURRENT_EPOCH=$(date +%s)
        DAYS_LEFT=$(( ($EXPIRY_EPOCH - $CURRENT_EPOCH) / 86400 ))
        if [ $DAYS_LEFT -lt 30 ]; then
            print_warning "Certificati SSL scadono tra $DAYS_LEFT giorni (rinnovo consigliato)"
        else
            print_success "Certificati SSL validi per $DAYS_LEFT giorni"
        fi
    else
        print_warning "Certificati SSL non trovati"
    fi
    
    # SmartCheck
    if docker ps --format '{{.Names}}' | grep -q smartcheck; then
        print_success "SmartCheck attivo"
    else
        print_warning "SmartCheck non in esecuzione"
    fi
}

cmd_logs() {
    local service="${2:-}"
    if [ -n "$service" ]; then
        print_info "Log $service (Ctrl+C per uscire):"
        docker compose logs -f "$service"
    else
        print_info "Log tutti i servizi (Ctrl+C per uscire):"
        docker compose logs -f
    fi
}

cmd_stop() {
    print_info "Arresto tutti i servizi..."
    docker compose down
    print_success "Servizi arrestati"
}

cmd_restart() {
    local service="${2:-}"
    if [ -n "$service" ]; then
        print_info "Riavvio $service..."
        docker compose restart "$service"
    else
        print_info "Riavvio tutti i servizi..."
        docker compose down
        docker compose up -d
    fi
    print_success "Riavvio completato"
}

cmd_update() {
    print_info "Aggiornamento immagini Docker..."
    docker compose pull
    print_info "Riavvio con nuove immagini..."
    # Se up -d fallisce, ricrea i container servizio per servizio (compose risolve
    # il nome del servizio nel relativo container_name)
    if ! docker compose up -d 2>/dev/null; then
        print_warning "docker compose up -d fallito"
        print_info "Ricreo i container uno per uno..."
        for svc in $(docker compose config --services); do
            docker compose rm -sf "$svc" 2>/dev/null || true
        done
        docker compose up -d
    fi
    print_success "Aggiornamento completato"
}

cmd_backup() {
    check_env
    print_info "Backup database Immich..."
    
    BACKUP_DIR="data/immich/backups"
    mkdir -p "$BACKUP_DIR"
    BACKUP_FILE="$BACKUP_DIR/immich-backup-$(date +%Y%m%d-%H%M%S).sql.gz"
    
    if docker compose exec -T immich-database pg_dump -U "${IMMICH_DB_USERNAME}" "${IMMICH_DB_DATABASE_NAME}" | gzip > "$BACKUP_FILE"; then
        BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
        print_success "Backup completato: $BACKUP_FILE ($BACKUP_SIZE)"
        
        # Mantieni ultimi 7 backup
        ls -t "$BACKUP_DIR"/immich-backup-*.sql.gz 2>/dev/null | tail -n +8 | xargs -r rm
        print_info "Backup disponibili:"
        ls -lh "$BACKUP_DIR"/immich-backup-*.sql.gz 2>/dev/null
    else
        print_error "Errore durante il backup!"
        exit 1
    fi
}

cmd_renew() {
    print_info "Verifica e rinnovo certificati SSL..."
    
    CERT_PATH="data/certbot/conf/live/REDACTED_HOSTNAME.REDACTED_DDNS/fullchain.pem"
    if [ ! -f "$CERT_PATH" ]; then
        print_error "Certificati non trovati. Esegui ./deploy.sh prima."
        exit 1
    fi
    
    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)
    EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s)
    CURRENT_EPOCH=$(date +%s)
    DAYS_LEFT=$(( ($EXPIRY_EPOCH - $CURRENT_EPOCH) / 86400 ))
    
    print_info "Certificato scade tra $DAYS_LEFT giorni"
    
    if [ $DAYS_LEFT -lt 30 ]; then
        print_info "Rinnovo necessario..."
        # Usa il servizio certbot dal docker-compose.yml — contiene la lista domini aggiornata
        if docker compose run --rm certbot; then
            print_success "Certificati rinnovati!"
            print_info "Ricarico nginx..."
            docker exec nginx nginx -s reload && print_success "Nginx ricaricato"
        else
            print_error "Errore rinnovo certificati!"
            exit 1
        fi
    else
        print_success "Certificati ancora validi per $DAYS_LEFT giorni (rinnovo non necessario)"
    fi
}

cmd_smartcheck() {
    print_info "Esecuzione check SMART immediato..."
    if docker ps --format '{{.Names}}' | grep -q smartcheck; then
        docker exec smartcheck smartctl -d sat -H /dev/smartcheck-nas2 2>&1 | grep -E 'PASSED|FAILED|result'
        echo "---"
        docker exec smartcheck smartctl -d sat -H /dev/smartcheck-nas 2>&1 | grep -E 'PASSED|FAILED|result'
        echo "---"
        print_info "Report completo NAS2:"
        docker exec smartcheck smartctl -d sat -A /dev/smartcheck-nas2 2>&1 | grep -E 'Reallocated|Pending|Temperature|Power_On'
        print_info "Report completo NAS:"
        docker exec smartcheck smartctl -d sat -A /dev/smartcheck-nas 2>&1 | grep -E 'Reallocated|Pending|Temperature|Power_On'
    else
        print_error "Container smartcheck non in esecuzione"
        exit 1
    fi
}

cmd_clean() {
    print_info "Pulizia Docker..."
    docker system prune -f
    docker image prune -f
    print_success "Pulizia completata"
}

cmd_reset() {
    print_warning "⚠️  ATTENZIONE: Questa operazione cancellerà TUTTI i dati Docker!"
    print_warning "Inclusi: foto Immich, database, configurazioni, certificati SSL"
    print_warning "NON tocca: /mnt/nas, /mnt/timemachine, /mnt/nas2 (fuori da data/)"
    echo ""
    read -p "Sei sicuro? Scrivi 'RESET' per confermare: " confirm
    
    if [ "$confirm" = "RESET" ]; then
        print_info "Arresto servizi..."
        docker compose down -v
        docker compose -f kickstart/docker-compose.yaml down -v 2>/dev/null || true
        
        print_info "Rimozione dati Docker (data/)..."
        rm -rf data/
        
        print_info "Pulizia Docker..."
        docker system prune -af
        
        print_success "Reset completato. Esegui ./deploy.sh per ricominciare."
    else
        print_info "Reset annullato"
    fi
}

cmd_sync() {
    case "${2:-}" in
        status)  docker compose --profile plex ps jellyplex-watched ;;
        logs)    docker compose --profile plex logs -f jellyplex-watched ;;
        restart) docker compose --profile plex restart jellyplex-watched ;;
        start)   docker compose --profile plex up -d jellyplex-watched ;;
        stop)    docker compose stop jellyplex-watched ;;
        *)
            echo "Uso: ./utils.sh sync [start|stop|status|logs|restart]"
            ;;
    esac
}

cmd_icloud() {
    case "${2:-status}" in
        start)
            check_env
            if [ -z "${ICLOUD_USERNAME:-}" ]; then
                print_error "Configura ICLOUD_USERNAME nel file .env"
                exit 1
            fi
            docker compose --profile icloud up -d icloudpd
            print_success "iCloud sync avviato"
            ;;
        stop)
            docker compose stop icloudpd
            docker compose rm -f icloudpd
            print_success "iCloud sync fermato"
            ;;
        status)
            if docker compose ps icloudpd 2>/dev/null | grep -q "Up"; then
                print_success "iCloudPD attivo"
            else
                print_warning "iCloudPD non attivo (avvia con: ./utils.sh icloud start)"
            fi
            ;;
        logs) docker compose logs -f icloudpd ;;
        *)    echo "Uso: ./utils.sh icloud [start|stop|status|logs]" ;;
    esac
}

# Main
case "${1:-}" in
    status)      cmd_status ;;
    logs)        cmd_logs "$@" ;;
    stop)        cmd_stop ;;
    restart)     cmd_restart "$@" ;;
    update)      cmd_update ;;
    backup)      cmd_backup ;;
    renew)       cmd_renew ;;
    smartcheck)  cmd_smartcheck ;;
    clean)       cmd_clean ;;
    reset)       cmd_reset ;;
    sync)        cmd_sync "$@" ;;
    icloud)      cmd_icloud "$@" ;;
    *)           show_usage ;;
esac
