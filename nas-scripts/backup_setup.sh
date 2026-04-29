#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# BACKUP OFFSITE — Script di setup
# =============================================================================
# Configura tutto il sistema di backup offsite: Borg + proton-drive-bridge + cron.
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
BRIDGE_BIN="/usr/local/bin/proton-drive-bridge"
BRIDGE_PORT="2121"
SESSION_PASSWORD="REDACTED_PROTON_SESSION_PASSWORD"
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

    local pkgs=(borgbackup lftp expect gnome-keyring dbus-x11 python3 curl)
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

    # Password Proton
    local proton_pass="$HOME/.proton-password"
    if [ -f "$proton_pass" ]; then
        log "Password Proton già presente: $proton_pass"
    else
        read -rsp "Inserisci la password Proton: " ppass
        echo
        echo "$ppass" > "$proton_pass"
        chmod 600 "$proton_pass"
        log "Password Proton salvata in $proton_pass"
    fi

    # OTP Secret Proton
    local otp_file="$HOME/.proton-otp-secret"
    if [ -f "$otp_file" ]; then
        log "Segreto OTP Proton già presente: $otp_file"
    else
        read -rp "Inserisci il segreto OTP Proton (base32, es. ABCD1234...): " otp
        echo "$otp" > "$otp_file"
        chmod 600 "$otp_file"
        log "Segreto OTP salvato in $otp_file"
    fi
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
# Step 4: proton-drive-bridge (binario)
# =============================================================================
setup_bridge_binary() {
    echo ""
    echo "============================================"
    echo "  Step 4: Installa proton-drive-bridge"
    echo "============================================"

    if [ -x "$BRIDGE_BIN" ]; then
        log "proton-drive-bridge già installato: $BRIDGE_BIN"
        "$BRIDGE_BIN" --version 2>/dev/null || true
        return
    fi

    info "Scarico proton-drive-bridge..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="x86_64-unknown-linux-gnu" ;;
        aarch64) arch="aarch64-unknown-linux-gnu" ;;
        *) err "Architettura non supportata: $arch" ;;
    esac

    info "Cercherò l'ultima release su GitHub: LLeny/proton-drive-bridge"
    info "Scarica manualmente da: https://github.com/LLeny/proton-drive-bridge/releases"
    info "Copia il binario in: $BRIDGE_BIN"
    info "  sudo cp proton-drive-bridge $BRIDGE_BIN"
    info "  sudo chmod +x $BRIDGE_BIN"
    rm -rf "$tmp_dir"
    warn "Installazione manuale necessaria per proton-drive-bridge"
}

# =============================================================================
# Step 5: Prima autenticazione bridge
# =============================================================================
setup_bridge_auth() {
    echo ""
    echo "============================================"
    echo "  Step 5: Autenticazione proton-drive-bridge"
    echo "============================================"

    if [ ! -x "$BRIDGE_BIN" ]; then
        warn "proton-drive-bridge non installato. Salta questo step."
        return
    fi

    local session_file="$HOME/.local/share/pdrive-bridge/pdrive-bridge.json"
    if [ -f "$session_file" ]; then
        log "Sessione bridge già presente. Per ri-autenticare, esegui:"
        info "  sudo systemctl stop proton-drive-bridge"
        info "  rm ~/.local/share/pdrive-bridge/pdrive-bridge.json"
        info "  $SCRIPTS_DIR/proton_refresh_session.sh"
        return
    fi

    info "Avvio prima autenticazione (richiede 2FA)..."
    if [ -x "$SCRIPTS_DIR/proton_refresh_session.sh" ]; then
        "$SCRIPTS_DIR/proton_refresh_session.sh"
    else
        warn "Script proton_refresh_session.sh non trovato."
        info "Avvia manualmente:"
        info "  eval \$(dbus-launch --sh-syntax)"
        info "  echo '' | gnome-keyring-daemon --unlock --components=secrets"
        info "  $BRIDGE_BIN --cli --username 'USER' --password 'PASS' --sessionpassword '$SESSION_PASSWORD' --port $BRIDGE_PORT"
    fi
}

# =============================================================================
# Step 6: Servizio systemd
# =============================================================================
setup_systemd() {
    echo ""
    echo "============================================"
    echo "  Step 6: Configura servizio systemd"
    echo "============================================"

    local service_file="/etc/systemd/system/proton-drive-bridge.service"
    local wrapper_bin="/usr/local/bin/proton-bridge-svc"
    local user
    user=$(whoami)

    info "Installo/aggiorno wrapper proton-bridge-svc..."
    sudo tee /usr/local/bin/proton-bridge-svc > /dev/null <<'EXPECTEOF'
#!/usr/bin/expect -f
# Wrapper expect per proton-drive-bridge in systemd.
# Risponde "q" su "Wrong session password" invece di loopare su ENTER.
# Exit 1 pulito → systemd ferma il servizio senza busy-loop CPU.

set timeout 30
set bridge_bin "/usr/local/bin/proton-drive-bridge"

eval spawn $bridge_bin {*}$argv

expect {
    "Wrong session password" {
        send "q\r"
        puts "\[bridge-svc\] Sessione corrotta — uscita pulita (exit 1)."
        exit 1
    }
    "FTP server listening" {
        set timeout -1
        expect eof
        exit 0
    }
    timeout {
        puts "\[bridge-svc\] Timeout: bridge non ha risposto entro 30s."
        exit 1
    }
    eof {
        exit 0
    }
}
EXPECTEOF
    sudo chmod +x /usr/local/bin/proton-bridge-svc

    info "Creo servizio systemd..."
    sudo tee "$service_file" > /dev/null <<EOF
[Unit]
Description=Proton Drive FTP Bridge
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${user}
Group=${user}
ExecStart=/bin/bash -c 'eval \$(dbus-launch --sh-syntax) && echo "" | gnome-keyring-daemon --unlock --components=secrets 2>/dev/null; exec /usr/local/bin/proton-bridge-svc --cli --sessionpassword "${SESSION_PASSWORD}" --port ${BRIDGE_PORT}'
Restart=on-failure
RestartSec=30
StartLimitIntervalSec=300
StartLimitBurst=3
StandardOutput=journal
StandardError=journal
SyslogIdentifier=proton-drive-bridge

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable proton-drive-bridge

    if systemctl is-active --quiet proton-drive-bridge; then
        log "Servizio già attivo — restart per applicare eventuali modifiche"
        sudo systemctl restart proton-drive-bridge
    else
        sudo systemctl start proton-drive-bridge
    fi
    sleep 3

    if systemctl is-active --quiet proton-drive-bridge; then
        log "Servizio avviato e abilitato"
    else
        warn "Servizio non partito. Controlla: journalctl -u proton-drive-bridge"
    fi
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
    info "Bridge FTP:          127.0.0.1:$BRIDGE_PORT"
    info "Destinazione Proton: /backup/tidepool"
    info "Script backup:       $SCRIPTS_DIR/backup_offsite.sh"
    info "Script refresh:      $SCRIPTS_DIR/proton_refresh_session.sh"
    info "Script restore:      $SCRIPTS_DIR/backup_restore.sh"
    info "Log:                 /var/log/backup-offsite.log"
    info "Cron:                03:00 ogni giorno"
    echo ""
    info "File credenziali (chmod 600):"
    info "  $HOME/.borg-offsite-passphrase"
    info "  $HOME/.proton-password"
    info "  $HOME/.proton-otp-secret"
    echo ""
    warn "IMPORTANTE: Salva la passphrase Borg in un luogo sicuro (password manager)."
    warn "Senza di essa i backup NON sono ripristinabili."
    echo ""
    info "Comandi utili:"
    info "  Stato bridge:     systemctl status proton-drive-bridge"
    info "  Log bridge:       journalctl -u proton-drive-bridge -f"
    info "  Backup manuale:   sudo $SCRIPTS_DIR/backup_offsite.sh"
    info "  Refresh sessione: $SCRIPTS_DIR/proton_refresh_session.sh"
    info "  Lista archivi:    BORG_PASSCOMMAND='cat ~/.borg-offsite-passphrase' borg list $REPO"
    info "  Restore:          $SCRIPTS_DIR/backup_restore.sh"
}

# =============================================================================
# Main
# =============================================================================

echo ""
echo "============================================"
echo "  BACKUP OFFSITE — SETUP"
echo "  Borg + proton-drive-bridge → Proton Drive"
echo "============================================"

setup_dependencies
setup_credentials
setup_borg_repo
setup_bridge_binary
setup_bridge_auth
setup_systemd
setup_cron
print_summary
