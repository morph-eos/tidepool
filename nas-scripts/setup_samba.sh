#!/bin/bash

# ============================================================================
# SETUP SAMBA + AVAHI - REDACTED_HOSTNAME_TC Cloud Platform
# ============================================================================
# Configures Samba (SMB) for NAS, NAS2 and Time Machine.
# Configures Avahi for discovery, restricted to the LAN.
# Configures UFW with LAN-only rules for Samba.
#
# Idempotent: can be rerun without damage.
# ============================================================================

set -e

LAN_INTERFACE="REDACTED_WIFI_IFACE"
LAN_SUBNET="192.0.2.0/24"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info()    { echo -e "${BLUE}ℹ${NC} $1"; }
print_success() { echo -e "${GREEN}✅${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_error()   { echo -e "${RED}❌${NC} $1"; }

echo "=== Configurazione Samba + Avahi ==="
echo ""

# === Dependencies ===
print_info "Verifica dipendenze..."
REQUIRED_PACKAGES="samba samba-vfs-modules attr avahi-daemon"
MISSING_PACKAGES=""
for pkg in $REQUIRED_PACKAGES; do
    if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        MISSING_PACKAGES="$MISSING_PACKAGES $pkg"
    fi
done
if [ -n "$MISSING_PACKAGES" ]; then
    print_info "Installazione:$MISSING_PACKAGES"
    sudo apt update && sudo apt install -y $MISSING_PACKAGES
else
    print_success "Dipendenze OK"
fi

# === Samba config ===
print_info "Configurazione Samba..."
sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true

sudo tee /etc/samba/smb.conf > /dev/null << 'SAMBAEOF'
[global]
   workgroup = WORKGROUP
   server string = Ubuntu NAS Server
   netbios name = ubuntu-nas
   security = user
   map to guest = never
   dns proxy = no

   # Security
   restrict anonymous = 2

   # Performance
   read raw = yes
   write raw = yes
   max xmit = 65535
   dead time = 15
   getwd cache = yes

   # Global Time Machine support
   fruit:aapl = yes
   fruit:nfs_aces = no
   fruit:copyfile = no
   fruit:model = MacSamba

   # Global VFS modules
   vfs objects = catia fruit streams_xattr

[NAS]
   comment = Network Attached Storage
   path = /mnt/nas
   browseable = yes
   writable = yes
   guest ok = no
   read only = no
   create mask = 0664
   force create mode = 0664
   directory mask = 0775
   force directory mode = 0775
   force user = REDACTED_HOSTNAME
   force group = REDACTED_HOSTNAME
   valid users = REDACTED_HOSTNAME
   # Disable mapping of DOS attrs to mode bits (no random exec/readonly)
   store dos attributes = no
   delete readonly = yes
   dos filemode = yes
   map archive = no
   map hidden = no
   map system = no
   map readonly = no

[NAS2]
   comment = Network Attached Storage 2 (2TB)
   path = /mnt/nas2
   browseable = yes
   writable = yes
   guest ok = no
   read only = no
   create mask = 0664
   force create mode = 0664
   directory mask = 0775
   force directory mode = 0775
   force user = REDACTED_HOSTNAME
   force group = REDACTED_HOSTNAME
   valid users = REDACTED_HOSTNAME
   store dos attributes = no
   delete readonly = yes
   dos filemode = yes
   map archive = no
   map hidden = no
   map system = no
   map readonly = no

[TimeMachine]
   comment = Time Machine Backup
   path = /mnt/timemachine
   browseable = yes
   writable = yes
   guest ok = no
   read only = no
   create mask = 0600
   directory mask = 0700
   force user = REDACTED_HOSTNAME
   force group = REDACTED_HOSTNAME
   valid users = REDACTED_HOSTNAME

   # Time Machine specific
   fruit:time machine = yes
   fruit:time machine max size = 3T
   fruit:advertise_fullsync = true

   # VFS modules for Time Machine
   vfs objects = catia fruit streams_xattr

   # Extended attributes for macOS
   ea support = yes
   store dos attributes = yes
   map acl inherit = yes
   map archive = no
   map hidden = no
   map read only = no
   map system = no
SAMBAEOF

print_success "smb.conf scritto"

# === Samba user ===
# Does NOT overwrite the password if the Samba user already exists
if sudo pdbedit -L 2>/dev/null | grep -q "^REDACTED_HOSTNAME:"; then
    print_success "Utente Samba 'REDACTED_HOSTNAME' già esistente — password invariata"
else
    print_info "Creazione utente Samba 'REDACTED_HOSTNAME'..."
    print_warning "Imposta la password Samba:"
    sudo smbpasswd -a REDACTED_HOSTNAME
    print_success "Utente Samba creato"
fi

sudo systemctl enable smbd
sudo systemctl restart smbd
print_success "Samba attivo"

# === Avahi config (LAN-only) ===
print_info "Configurazione Avahi (ristretto a $LAN_INTERFACE)..."
sudo tee /etc/avahi/avahi-daemon.conf > /dev/null << AVAHIEOF
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
AVAHIEOF

sudo systemctl enable avahi-daemon
sudo systemctl restart avahi-daemon
print_success "Avahi attivo (solo $LAN_INTERFACE)"

# === UFW: Samba LAN-only ===
print_info "Configurazione UFW per Samba (LAN only: $LAN_SUBNET)..."

# Remove generic "Samba" rules (open to everyone) if they exist
sudo ufw delete allow Samba 2>/dev/null || true
sudo ufw delete allow samba 2>/dev/null || true

# Add LAN-only rules (idempotent — ufw ignores duplicates)
sudo ufw allow from "$LAN_SUBNET" to any port 139 proto tcp comment "Samba LAN only" 2>/dev/null || true
sudo ufw allow from "$LAN_SUBNET" to any port 445 proto tcp comment "Samba LAN only" 2>/dev/null || true
sudo ufw allow from "$LAN_SUBNET" to any port 21027 proto udp comment "Syncthing discovery LAN" 2>/dev/null || true

print_success "UFW configurato per Samba LAN-only"

# === Summary ===
echo ""
IP_ADDRESS=$(hostname -I | awk '{print $1}')
print_success "=== Configurazione completata ==="
echo ""
print_info "Condivisioni disponibili:"
echo "  NAS:         \\\\$IP_ADDRESS\\NAS          (smb://$IP_ADDRESS/NAS)"
echo "  NAS2:        \\\\$IP_ADDRESS\\NAS2         (smb://$IP_ADDRESS/NAS2)"
echo "  TimeMachine: \\\\$IP_ADDRESS\\TimeMachine  (smb://$IP_ADDRESS/TimeMachine)"
echo ""
print_info "Utente: REDACTED_HOSTNAME (cambia password con: sudo smbpasswd REDACTED_HOSTNAME)"
