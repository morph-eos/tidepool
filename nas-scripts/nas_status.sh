#!/bin/bash

# ============================================================================
# NAS STATUS - REDACTED_HOSTNAME_TC Cloud Platform
# ============================================================================
# Quick status check — mounts, services, disk space, SMART.
# ============================================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✅${NC} $1"; }
fail() { echo -e "  ${RED}❌${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }

echo "=== REDACTED_HOSTNAME_TC Quick Status ==="
echo ""

# Mounts
echo "📦 Mount:"
for mp in /mnt/nas /mnt/nas2 /mnt/timemachine; do
    if mountpoint -q "$mp" 2>/dev/null; then
        usage=$(df -h "$mp" | awk 'NR==2 {print $5 " used (" $4 " free)"}')
        ok "$mp — $usage"
    else
        fail "$mp NON MONTATO"
    fi
done
echo ""

# Docker
echo "🐳 Container:"
for c in nginx immich_server immich_postgres immich_redis immich_machine_learning jellyfin nextcloud nextcloud_mariadb nextcloud_redis vaultwarden syncthing webdav smartcheck; do
    if docker ps --format '{{.Names}}' | grep -q "^${c}$"; then
        ok "$c"
    else
        if docker ps -a --format '{{.Names}}' | grep -q "^${c}$"; then
            fail "$c (stopped)"
        else
            warn "$c (not found)"
        fi
    fi
done
echo ""

# System services
echo "🔧 Servizi:"
for svc in smbd avahi-daemon sshd; do
    if systemctl is-active "$svc" &>/dev/null; then
        ok "$svc"
    else
        fail "$svc"
    fi
done

# UFW
if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
    ok "ufw (active)"
else
    warn "ufw (inactive)"
fi
echo ""

# SMART (if the smartcheck container is running)
echo "💽 SMART:"
if docker ps --format '{{.Names}}' | grep -q smartcheck; then
    for dev in /dev/smartcheck-nas2 /dev/smartcheck-nas; do
        result=$(docker exec smartcheck smartctl -d sat -H "$dev" 2>&1)
        if echo "$result" | grep -qi "PASSED"; then
            ok "$dev — PASSED"
        elif echo "$result" | grep -qi "FAILED"; then
            fail "$dev — FAILED!"
        else
            warn "$dev — impossibile verificare"
        fi
    done
else
    warn "SmartCheck non attivo"
fi
echo ""

# Cert
CERT="/mnt/nas2/docker/data/certbot/conf/live/REDACTED_HOSTNAME.REDACTED_DDNS/fullchain.pem"
if [ -f "$CERT" ]; then
    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT" | cut -d= -f2)
    DAYS=$(( ($(date -d "$EXPIRY" +%s) - $(date +%s)) / 86400 ))
    if [ $DAYS -lt 30 ]; then
        warn "SSL scade tra $DAYS giorni"
    else
        ok "SSL valido per $DAYS giorni"
    fi
else
    fail "Certificati SSL non trovati"
fi
