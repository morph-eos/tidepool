#!/bin/bash

# ============================================================================
# FIX NAS - REDACTED_HOSTNAME_TC Cloud Platform
# ============================================================================
# Ripara fstab e rimonta i dischi NAS usando UUID.
# Rileva i dischi via serial number — sicuro anche se /dev/sdX cambia.
#
# Uso: sudo ./fix_nas.sh
# ============================================================================

set -e

NAS_SERIAL="REDACTED_DISK_SERIAL"
NAS2_SERIAL="REDACTED_DISK_SERIAL"
TIMEMACHINE_MOUNT="/mnt/timemachine"
NAS_MOUNT="/mnt/nas"
NAS2_MOUNT="/mnt/nas2"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info()    { echo -e "${BLUE}ℹ${NC} $1"; }
print_success() { echo -e "${GREEN}✅${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_error()   { echo -e "${RED}❌${NC} $1"; }

find_disk_by_serial() {
    local serial="$1"
    for dev in /sys/block/sd*; do
        local devname=$(basename "$dev")
        local dev_serial=$(udevadm info --query=property --name="/dev/$devname" 2>/dev/null | grep '^ID_SERIAL_SHORT=' | cut -d= -f2)
        if [ "$dev_serial" = "$serial" ]; then
            echo "/dev/$devname"
            return
        fi
    done
}

echo "=== Riparazione configurazione NAS ==="
echo ""

# Rileva dischi
DISK1=$(find_disk_by_serial "$NAS_SERIAL")
DISK2=$(find_disk_by_serial "$NAS2_SERIAL")

if [ -z "$DISK1" ]; then
    print_error "Disco NAS (serial $NAS_SERIAL) non trovato!"
    exit 1
fi
if [ -z "$DISK2" ]; then
    print_error "Disco NAS2 (serial $NAS2_SERIAL) non trovato!"
    exit 1
fi

print_success "NAS: $DISK1"
print_success "NAS2: $DISK2"

print_info "Backup fstab corrente..."
sudo cp /etc/fstab "/etc/fstab.fix_$(date +%Y%m%d_%H%M%S)"

print_info "Smontaggio partizioni..."
sudo umount "$TIMEMACHINE_MOUNT" 2>/dev/null || true
sudo umount "$NAS_MOUNT" 2>/dev/null || true
sudo umount "$NAS2_MOUNT" 2>/dev/null || true

# Verifica partizioni disco 1
if [ ! -e "${DISK1}1" ] || [ ! -e "${DISK1}2" ]; then
    print_error "Partizioni ${DISK1}1 / ${DISK1}2 non trovate!"
    sudo fdisk -l "$DISK1"
    exit 1
fi

# Determina device NAS2 (partizione o disco intero)
NAS2_DEV=""
if [ -e "${DISK2}1" ] && sudo blkid "${DISK2}1" 2>/dev/null | grep -q 'TYPE='; then
    NAS2_DEV="${DISK2}1"
elif sudo blkid "$DISK2" 2>/dev/null | grep -q 'TYPE='; then
    NAS2_DEV="$DISK2"
else
    print_error "Nessun filesystem trovato su $DISK2!"
    exit 1
fi

NAS_UUID=$(sudo blkid -s UUID -o value "${DISK1}1")
TM_UUID=$(sudo blkid -s UUID -o value "${DISK1}2")
NAS2_UUID=$(sudo blkid -s UUID -o value "$NAS2_DEV")

if [ -z "$NAS_UUID" ] || [ -z "$TM_UUID" ] || [ -z "$NAS2_UUID" ]; then
    print_error "UUID mancanti!"
    echo "NAS: $NAS_UUID, TM: $TM_UUID, NAS2: $NAS2_UUID"
    exit 1
fi

print_info "UUID NAS: $NAS_UUID"
print_info "UUID TimeMachine: $TM_UUID"
print_info "UUID NAS2: $NAS2_UUID"

print_info "Pulizia fstab..."
sudo sed -i '\|/mnt/timemachine|d' /etc/fstab
sudo sed -i '\| /mnt/nas |d' /etc/fstab
sudo sed -i '\| /mnt/nas$|d' /etc/fstab
sudo sed -i '\|/mnt/nas2|d' /etc/fstab

print_info "Scrittura nuove entry fstab con UUID..."
echo "UUID=$NAS_UUID $NAS_MOUNT ext4 defaults 0 2" | sudo tee -a /etc/fstab
echo "UUID=$TM_UUID $TIMEMACHINE_MOUNT hfsplus defaults,uid=1000,gid=1000,umask=0000 0 2" | sudo tee -a /etc/fstab
echo "UUID=$NAS2_UUID $NAS2_MOUNT ext4 defaults 0 2" | sudo tee -a /etc/fstab

sudo mkdir -p "$TIMEMACHINE_MOUNT" "$NAS_MOUNT" "$NAS2_MOUNT"

print_info "Mount partizioni..."
sudo mount "$NAS_MOUNT"
sudo mount "$TIMEMACHINE_MOUNT"
sudo mount "$NAS2_MOUNT"

print_info "Permessi..."
sudo chown REDACTED_HOSTNAME:REDACTED_HOSTNAME "$NAS_MOUNT" "$TIMEMACHINE_MOUNT" "$NAS2_MOUNT"
sudo chmod 755 "$NAS_MOUNT" "$TIMEMACHINE_MOUNT" "$NAS2_MOUNT"

print_info "Verifica finale:"
df -h "$NAS_MOUNT" "$TIMEMACHINE_MOUNT" "$NAS2_MOUNT"
echo ""
print_info "fstab:"
grep -E "/mnt/(timemachine|nas)" /etc/fstab
echo ""
print_success "Riparazione completata!"
