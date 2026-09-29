#!/bin/bash

# ============================================================================
# SETUP DISK - REDACTED_HOSTNAME_TC Cloud Platform
# ============================================================================
# Configures the NAS disks safely using the disks' serial numbers.
# Does NOT use a hardcoded /dev/sdX — detects dynamically via udevadm.
#
# Expected disks:
#   - REDACTED_DISK_MODEL (serial REDACTED_DISK_SERIAL): NAS (part1 ext4) + TimeMachine (part2 HFS+)
#   - REDACTED_DISK_MODEL (serial REDACTED_DISK_SERIAL): NAS2 (whole disk, ext4)
#
# Usage: ./setup_disk.sh [--force]
#      --force: skip the interactive confirmations
#
# The script is idempotent: if the disks are already mounted and OK, it does nothing.
# ============================================================================

set -e

# === Disk identification via serial number ===
# These are the disks' physical serial numbers, they NEVER change.
NAS_SERIAL="REDACTED_DISK_SERIAL"        # REDACTED_DISK_MODEL (NAS + TimeMachine)
NAS2_SERIAL="REDACTED_DISK_SERIAL"   # REDACTED_DISK_MODEL (NAS2)

MOUNT_BASE="/mnt"
TIMEMACHINE_MOUNT="$MOUNT_BASE/timemachine"
NAS_MOUNT="$MOUNT_BASE/nas"
NAS2_MOUNT="$MOUNT_BASE/nas2"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info()    { echo -e "${BLUE}ℹ${NC} $1"; }
print_success() { echo -e "${GREEN}✅${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_error()   { echo -e "${RED}❌${NC} $1"; }

# Check --force
AUTO_MODE=false
[ "${1:-}" = "--force" ] && AUTO_MODE=true

confirm_or_skip() {
    if [ "$AUTO_MODE" = true ]; then return 0; fi
    echo -e "${YELLOW}$1${NC}"
    read -p "Premi INVIO per continuare o CTRL+C per annullare... "
}

# === Function: find device from serial ===
find_disk_by_serial() {
    local serial="$1"
    local found=""
    for dev in /sys/block/sd*; do
        local devname=$(basename "$dev")
        local dev_serial=$(udevadm info --query=property --name="/dev/$devname" 2>/dev/null | grep '^ID_SERIAL_SHORT=' | cut -d= -f2)
        if [ "$dev_serial" = "$serial" ]; then
            found="/dev/$devname"
            break
        fi
    done
    echo "$found"
}

# === Function: install dependencies ===
install_dependencies() {
    print_info "Verifica dipendenze..."
    REQUIRED_PACKAGES="parted hfsprogs samba avahi-daemon"
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
}

# === Function: create udev rules for stable symlinks ===
setup_udev_rules() {
    local UDEV_FILE="/etc/udev/rules.d/99-smartcheck-disks.rules"
    if [ -f "$UDEV_FILE" ]; then
        print_success "Regole udev già presenti: $UDEV_FILE"
    else
        print_info "Creazione regole udev per symlink stabili..."
        sudo tee "$UDEV_FILE" > /dev/null << 'UDEV'
# Stable symlinks for smartcheck and disk identification
# NAS2 (USB, serial REDACTED_DISK_SERIAL) - whole disk only
SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ENV{ID_SERIAL_SHORT}=="REDACTED_DISK_SERIAL", SYMLINK+="smartcheck-nas2"
# NAS (USB, serial REDACTED_DISK_SERIAL) - whole disk only
SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ENV{ID_SERIAL_SHORT}=="REDACTED_DISK_SERIAL", SYMLINK+="smartcheck-nas"
UDEV
        sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=block
        sleep 1
        print_success "Regole udev create e attivate"
    fi

    local AUTOSUSPEND_FILE="/etc/udev/rules.d/99-usb-storage-no-autosuspend.rules"
    if [ -f "$AUTOSUSPEND_FILE" ]; then
        print_success "Regola autosuspend USB già presente: $AUTOSUSPEND_FILE"
    else
        print_info "Creazione regola udev per disabilitare USB autosuspend..."
        sudo tee "$AUTOSUSPEND_FILE" > /dev/null << 'UDEV'
# Disable USB autosuspend for all USB storage devices
# Prevents system freezes caused by random disconnections of the USB disks
ACTION=="add", SUBSYSTEM=="usb", DRIVER=="usb", ATTR{idVendor}=="REDACTED_USB_VENDOR_ID", ATTR{idProduct}=="REDACTED_USB_PRODUCT_ID", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="08", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="usb", ATTR{bDeviceClass}=="08", ATTR{power/control}="on"
UDEV
        sudo udevadm control --reload-rules
        print_success "Regola autosuspend USB creata"
    fi
}

# === Disk detection ===
print_info "Rilevamento dischi via serial number..."

DISK1=$(find_disk_by_serial "$NAS_SERIAL")
DISK2=$(find_disk_by_serial "$NAS2_SERIAL")

if [ -z "$DISK1" ]; then
    print_error "Disco NAS (serial $NAS_SERIAL) non trovato!"
    print_info "Collega il disco e riprova."
    exit 1
fi

if [ -z "$DISK2" ]; then
    print_error "Disco NAS2 (serial $NAS2_SERIAL) non trovato!"
    print_info "Collega il disco e riprova."
    exit 1
fi

print_success "NAS trovato: $DISK1 (serial $NAS_SERIAL)"
print_success "NAS2 trovato: $DISK2 (serial $NAS2_SERIAL)"

# === Dependency installation ===
install_dependencies

# === udev rules ===
setup_udev_rules

# === Check current state ===
print_info "Verifica stato mount corrente..."

DISK1_OK=true
DISK2_OK=true

# Disk 1: check NAS and TimeMachine
if mountpoint -q "$NAS_MOUNT" 2>/dev/null; then
    print_success "NAS già montato: $NAS_MOUNT"
else
    print_warning "NAS non montato"
    DISK1_OK=false
fi

if mountpoint -q "$TIMEMACHINE_MOUNT" 2>/dev/null; then
    print_success "TimeMachine già montata: $TIMEMACHINE_MOUNT"
else
    print_warning "TimeMachine non montata"
    DISK1_OK=false
fi

# Disk 2: check NAS2
if mountpoint -q "$NAS2_MOUNT" 2>/dev/null; then
    print_success "NAS2 già montato: $NAS2_MOUNT"
else
    print_warning "NAS2 non montato"
    DISK2_OK=false
fi

# If everything is mounted, check that fstab uses UUIDs (not /dev/sdX)
if [ "$DISK1_OK" = true ] && [ "$DISK2_OK" = true ]; then
    FSTAB_OK=true
    if grep -q "/dev/sd.*$NAS_MOUNT" /etc/fstab 2>/dev/null; then
        print_warning "fstab usa /dev/sdX per NAS — va corretto con UUID"
        FSTAB_OK=false
    fi
    if grep -q "/dev/sd.*$NAS2_MOUNT" /etc/fstab 2>/dev/null; then
        print_warning "fstab usa /dev/sdX per NAS2 — va corretto con UUID"
        FSTAB_OK=false
    fi
    if [ "$FSTAB_OK" = true ]; then
        print_success "Tutti i dischi montati e fstab usa UUID. Nessuna azione necessaria."
        exit 0
    fi
fi

# === Disk 1 configuration (NAS) ===
if [ "$DISK1_OK" = false ]; then
    # Check whether it already has valid partitions
    if sudo blkid "${DISK1}1" 2>/dev/null | grep -q 'TYPE="ext4"' && \
       sudo blkid "${DISK1}2" 2>/dev/null | grep -q 'TYPE="hfsplus"'; then
        print_info "Disco 1 ha partizioni valide, serve solo il mount..."
    else
        confirm_or_skip "⚠️  Disco 1 ($DISK1) richiede partizionamento. TUTTI I DATI VERRANNO PERSI!"
        
        print_info "Smontaggio partizioni esistenti di $DISK1..."
        for part in $(mount | grep "^$DISK1" | awk '{print $1}'); do
            sudo umount "$part" 2>/dev/null || sudo umount -l "$part" 2>/dev/null || true
        done
        
        print_info "Partizionamento $DISK1..."
        sudo wipefs -a "$DISK1" || true
        sudo parted "$DISK1" --script mklabel gpt
        sudo parted "$DISK1" --script mkpart primary ext4 1MiB 13TB
        sudo parted "$DISK1" --script mkpart primary hfsx 13TB 100%
        sudo partprobe "$DISK1"
        sleep 3
        
        print_info "Formattazione NAS (ext4)..."
        sudo mkfs.ext4 -F -L "NAS" "${DISK1}1"
        
        print_info "Formattazione TimeMachine (HFS+)..."
        sudo mkfs.hfsplus -v "TimeMachine" "${DISK1}2" || {
            print_warning "HFS+ fallito, uso exFAT come fallback..."
            sudo mkfs.exfat -n "TimeMachine" "${DISK1}2"
        }
    fi
    
    # Mount
    sudo mkdir -p "$NAS_MOUNT" "$TIMEMACHINE_MOUNT"
    
    NAS_UUID=$(sudo blkid -s UUID -o value "${DISK1}1")
    TM_UUID=$(sudo blkid -s UUID -o value "${DISK1}2")
    
    # Update fstab (removes old entries, adds with UUID)
    sudo sed -i '\|/mnt/timemachine|d' /etc/fstab
    sudo sed -i '\|/mnt/nas[^2]|d' /etc/fstab
    # Also remove exact /mnt/nas entries (without /mnt/nas2)
    sudo sed -i '\| /mnt/nas |d' /etc/fstab
    
    echo "UUID=$NAS_UUID $NAS_MOUNT ext4 defaults 0 2" | sudo tee -a /etc/fstab
    echo "UUID=$TM_UUID $TIMEMACHINE_MOUNT hfsplus defaults,uid=1000,gid=1000,umask=0000 0 2" | sudo tee -a /etc/fstab
    
    sudo mount "$NAS_MOUNT" || true
    sudo mount "$TIMEMACHINE_MOUNT" || true
    
    sudo chown REDACTED_HOSTNAME:REDACTED_HOSTNAME "$NAS_MOUNT" "$TIMEMACHINE_MOUNT"
    sudo chmod 755 "$NAS_MOUNT" "$TIMEMACHINE_MOUNT"
    
    print_success "Disco 1 configurato: NAS=$NAS_MOUNT, TimeMachine=$TIMEMACHINE_MOUNT"
fi

# === Disk 2 configuration (NAS2) ===
if [ "$DISK2_OK" = false ]; then
    # The USB disk has no numbered partitions — it can be formatted directly
    # or have a ${DISK2}1 partition
    NAS2_DEV=""
    if sudo blkid "${DISK2}1" 2>/dev/null | grep -q 'TYPE="ext4"'; then
        NAS2_DEV="${DISK2}1"
        print_info "NAS2 ha partizione ext4 esistente ($NAS2_DEV), serve solo il mount..."
    elif sudo blkid "$DISK2" 2>/dev/null | grep -q 'TYPE="ext4"'; then
        NAS2_DEV="$DISK2"
        print_info "NAS2 formattato direttamente ($NAS2_DEV), serve solo il mount..."
    else
        confirm_or_skip "⚠️  Disco 2 ($DISK2) richiede formattazione. TUTTI I DATI VERRANNO PERSI!"
        
        print_info "Smontaggio e partizionamento $DISK2..."
        for part in $(mount | grep "^$DISK2" | awk '{print $1}'); do
            sudo umount "$part" 2>/dev/null || sudo umount -l "$part" 2>/dev/null || true
        done
        
        sudo wipefs -a "$DISK2" || true
        sudo parted "$DISK2" --script mklabel gpt
        sudo parted "$DISK2" --script mkpart primary ext4 1MiB 100%
        sudo partprobe "$DISK2"
        sleep 3
        
        sudo mkfs.ext4 -F -L "NAS2" "${DISK2}1"
        NAS2_DEV="${DISK2}1"
    fi
    
    sudo mkdir -p "$NAS2_MOUNT"
    
    NAS2_UUID=$(sudo blkid -s UUID -o value "$NAS2_DEV")
    
    sudo sed -i '\|/mnt/nas2|d' /etc/fstab
    echo "UUID=$NAS2_UUID $NAS2_MOUNT ext4 defaults 0 2" | sudo tee -a /etc/fstab
    
    sudo mount "$NAS2_MOUNT" || true
    sudo chown REDACTED_HOSTNAME:REDACTED_HOSTNAME "$NAS2_MOUNT"
    sudo chmod 755 "$NAS2_MOUNT"
    
    print_success "Disco 2 configurato: NAS2=$NAS2_MOUNT"
fi

echo ""
print_success "=== Configurazione dischi completata ==="
print_info "NAS:         $NAS_MOUNT (serial $NAS_SERIAL)"
print_info "TimeMachine: $TIMEMACHINE_MOUNT"
print_info "NAS2:        $NAS2_MOUNT (serial $NAS2_SERIAL)"
echo ""
df -h "$NAS_MOUNT" "$TIMEMACHINE_MOUNT" "$NAS2_MOUNT" 2>/dev/null
