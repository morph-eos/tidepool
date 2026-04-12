#!/bin/bash

# ============================================================================
# NAS INFO - REDACTED_HOSTNAME_TC Cloud Platform
# ============================================================================
# Mostra informazioni di sistema rilevando i dischi dinamicamente.
# ============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}           REDACTED_HOSTNAME_TC Cloud Platform — Info${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""

# === Sistema ===
echo -e "${BLUE}📋 Sistema${NC}"
echo "  Hostname:  $(hostname)"
echo "  OS:        $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')"
echo "  Kernel:    $(uname -r)"
echo "  Uptime:    $(uptime -p)"
echo "  CPU:       $(nproc) core(s)"
echo "  RAM:       $(free -h | awk '/Mem:/ {printf "%s / %s (used %s)", $3, $2, $5}')"
echo ""

# === Storage (dinamico) ===
echo -e "${BLUE}💾 Storage${NC}"
for mp in /mnt/nas /mnt/nas2 /mnt/timemachine; do
    if mountpoint -q "$mp" 2>/dev/null; then
        dev=$(findmnt -no SOURCE "$mp")
        size=$(df -h "$mp" | awk 'NR==2 {printf "%s total, %s used (%s)", $2, $3, $5}')
        echo "  $mp → $dev ($size)"
    else
        echo -e "  $mp → ${YELLOW}NON MONTATO${NC}"
    fi
done
echo ""

# === Rete ===
echo -e "${BLUE}🌐 Rete${NC}"
echo "  IP LAN:    $(hostname -I | awk '{print $1}')"
echo "  Interface: $(ip route | grep default | awk '{print $5}' | head -1)"
echo ""

# === Servizi ===
echo -e "${BLUE}🐳 Docker${NC}"
if command -v docker compose &>/dev/null; then
    docker compose ps --format 'table {{.Name}}\t{{.State}}' 2>/dev/null || docker compose ps 2>/dev/null
else
    echo "  docker compose non disponibile"
fi
echo ""

echo -e "${BLUE}🔒 Firewall (UFW)${NC}"
sudo ufw status 2>/dev/null | head -15 || echo "  UFW non disponibile"
echo ""

echo -e "${BLUE}📁 Samba${NC}"
if systemctl is-active smbd &>/dev/null; then
    echo "  Stato: attivo"
    smbstatus -S 2>/dev/null | head -10 || echo "  (nessuna sessione attiva)"
else
    echo "  Stato: inattivo"
fi
echo ""

echo -e "${BLUE}🔑 Accesso${NC}"
echo "  SSH:    ssh REDACTED_HOSTNAME@$(hostname -I | awk '{print $1}') -p 2222"
echo "  Samba:  smb://$(hostname -I | awk '{print $1}')/NAS"
echo "  Web:    https://REDACTED_HOSTNAME.REDACTED_DDNS"
