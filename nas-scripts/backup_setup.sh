#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# BACKUP OFFSITE — Script di setup
# =============================================================================
# Configura il sistema di backup offsite: Borg + Proton Drive CLI (timer) + cron.
# Eseguire come utente corrente (richiede sudo per alcune operazioni).
#
# Uso: ./backup_setup.sh
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

REPO="/mnt/nas/backup/offsite"
SCRIPTS_DIR="/mnt/nas2/nas-scripts"

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $*"; }

# =============================================================================
# Step 1: Dipendenze
# =============================================================================
setup_dependencies() {
    echo ""
    echo "============================================"
    echo "  Step 1: Installa dipendenze"
    echo "============================================"

    local pkgs=(borgbackup gnome-keyring dbus-x11 python3 curl)
    local to_install=()

    for pkg in "${pkgs[@]}"; do
        if ! dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
            to_install+=("$pkg")
        fi
    done

    if [ ${#to_install[@]} -gt 0 ]; then
        info "Installo: ${to_install[*]}"
        sudo apt update -qq
        sudo apt install -y "${to_install[@]}"
        log "Dipendenze installate"
    else
        log "Tutte le dipendenze già presenti"
    fi
}

# =============================================================================
# Step 2: Credenziali
# =============================================================================
setup_credentials() {
    echo ""
    echo "============================================"
    echo "  Step 2: Configura credenziali"
    echo "============================================"

    # Passphrase Borg
    local borg_file="$HOME/.borg-offsite-passphrase"
    if [ -f "$borg_file" ]; then
        log "Passphrase Borg già presente: $borg_file"
    else
        read -rsp "Inserisci la passphrase Borg (generarla con: openssl rand -base64 32): " passphrase
        echo
        echo "$passphrase" > "$borg_file"
        chmod 600 "$borg_file"
        log "Passphrase Borg salvata in $borg_file"
        warn "SALVA QUESTA PASSPHRASE IN UN LUOGO SICURO! Senza non puoi ripristinare."
    fi

    # Proton: nessuna password/OTP da salvare — il CLI ufficiale usa login via
    # browser una-tantum ("proton-drive auth login"), sessione in libsecret.
}

# =============================================================================
# Step 3: Repository Borg
# =============================================================================
setup_borg_repo() {
    echo ""
    echo "============================================"
    echo "  Step 3: Inizializza repository Borg"
    echo "============================================"

    export BORG_PASSCOMMAND="cat $HOME/.borg-offsite-passphrase"

    if [ -d "$REPO/data" ]; then
        log "Repository Borg già inizializzato: $REPO"
        borg info "$REPO" 2>/dev/null | head -5
    else
        info "Inizializzo repository Borg..."
        mkdir -p "$REPO"
        borg init --encryption=repokey "$REPO"
        log "Repository Borg creato: $REPO"
        warn "Esporta la chiave con: borg key export $REPO > borg-key-backup.txt"
    fi
}

# =============================================================================
# Step 4: Proton Drive CLI (mirror offsite) + systemd timer
# =============================================================================
setup_proton_cli() {
    echo ""
    echo "============================================"
    echo "  Step 4: Proton Drive CLI + systemd timer"
    echo "============================================"
    local u=REDACTED_HOSTNAME
    local uid; uid=$(id -u "$u")
    if [ -x "$SCRIPTS_DIR/setup_proton_cli_backup.sh" ]; then
        sudo -u "$u" env XDG_RUNTIME_DIR="/run/user/$uid" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
            "$SCRIPTS_DIR/setup_proton_cli_backup.sh" || warn "Rivedere output setup_proton_cli_backup.sh"
    else
        warn "setup_proton_cli_backup.sh non trovato in $SCRIPTS_DIR"
    fi
    info "LOGIN una-tantum (monitor collegato, sessione GNOME di $u):"
    info "  proton-drive auth login"
    info "Il mirror gira via systemd USER timer proton-cli-backup.timer (03:30)."
}

# =============================================================================
# Step 7: Cron
# =============================================================================
setup_cron() {
    echo ""
    echo "============================================"
    echo "  Step 7: Configura cron backup giornaliero"
    echo "============================================"

    local cron_line="0 3 * * * sudo ${SCRIPTS_DIR}/backup_offsite.sh >> /var/log/backup-offsite.log 2>&1"

    if crontab -l 2>/dev/null | grep -qF "backup_offsite.sh"; then
        log "Cron job già configurato:"
        crontab -l | grep "backup_offsite"
    else
        (crontab -l 2>/dev/null; echo "# Backup offsite quotidiano alle 03:00"; echo "$cron_line") | crontab -
        log "Cron job aggiunto: ogni giorno alle 03:00"
    fi
}

# =============================================================================
# Riepilogo
# =============================================================================
print_summary() {
    echo ""
    echo "============================================"
    echo "  Setup completato — Riepilogo"
    echo "============================================"
    echo ""
    info "Repository Borg:     $REPO"
    info "Destinazione Proton: /my-files/backup/tidepool (CLI)"
    info "Script backup:       $SCRIPTS_DIR/backup_offsite.sh"
    info "Mirror Proton:       $SCRIPTS_DIR/proton_cli_backup.sh (systemd user timer 03:30)"
    info "Script restore:      $SCRIPTS_DIR/backup_restore.sh"
    info "Log:                 /var/log/backup-offsite.log"
    info "Cron:                03:00 ogni giorno"
    echo ""
    info "File credenziali (chmod 600):"
    info "  $HOME/.borg-offsite-passphrase"
    echo ""
    warn "IMPORTANTE: Salva la passphrase Borg in un luogo sicuro (password manager)."
    warn "Senza di essa i backup NON sono ripristinabili."
    echo ""
    info "Comandi utili:"
    info "  Log mirror:       tail -f /var/log/proton-cli-backup.log"
    info "  Backup manuale:   sudo $SCRIPTS_DIR/backup_offsite.sh"
    info "  Login Proton:     proton-drive auth login   (una-tantum, GUI)"
    info "  Lista archivi:    BORG_PASSCOMMAND='cat ~/.borg-offsite-passphrase' borg list $REPO"
    info "  Restore:          $SCRIPTS_DIR/backup_restore.sh"
}

# =============================================================================
# Main
# =============================================================================

echo ""
echo "============================================"
echo "  BACKUP OFFSITE — SETUP"
echo "  Borg + Proton Drive CLI (mirror via timer)"
echo "============================================"

setup_dependencies
setup_credentials
setup_borg_repo
setup_proton_cli
setup_cron
print_summary
