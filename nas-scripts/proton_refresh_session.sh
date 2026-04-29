#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# PROTON DRIVE BRIDGE — Refresh sessione automatico con 2FA
# =============================================================================
# Rigenera la sessione del bridge quando scade il token Proton.
# Usa il segreto OTP per generare il codice 2FA automaticamente.
# Chiamato automaticamente da backup_offsite.sh se il bridge non risponde.
# =============================================================================

BRIDGE_BIN="/usr/local/bin/proton-drive-bridge"
BRIDGE_PORT="2121"
SESSION_PASSWORD="REDACTED_PROTON_SESSION_PASSWORD"
PROTON_USER="REDACTED_OWNER_EMAIL"
PROTON_PASS_FILE="/home/REDACTED_HOSTNAME/.proton-password"
OTP_SECRET_FILE="/home/REDACTED_HOSTNAME/.proton-otp-secret"
SESSION_DIR="/root/.local/share/pdrive-bridge"

log() { echo "$(date -Is) - [proton-refresh] $*"; }

die() { log "ERRORE: $*"; exit 1; }

# --- Genera codice TOTP ------------------------------------------------------

generate_totp() {
    local secret
    secret=$(cat "$OTP_SECRET_FILE")
    python3 -c "
import hmac, hashlib, struct, time, base64
key = base64.b32decode('${secret}')
t = int(time.time()) // 30
h = hmac.new(key, struct.pack('>Q', t), hashlib.sha1).digest()
o = h[-1] & 0xf
code = (struct.unpack('>I', h[o:o+4])[0] & 0x7fffffff) % 1000000
print(f'{code:06d}')
"
}

# --- Controlla se il bridge risponde -----------------------------------------

bridge_is_alive() {
    curl -s -o /dev/null --max-time 5 ftp://127.0.0.1:${BRIDGE_PORT}/ --user "${PROTON_USER}:" 2>/dev/null
}

# --- Main --------------------------------------------------------------------

# Se il bridge risponde, non fare nulla
if bridge_is_alive; then
    log "Bridge già attivo e funzionante. Nessuna azione necessaria."
    exit 0
fi

log "Bridge non risponde. Avvio refresh sessione..."

# Pre-check
[ -f "$PROTON_PASS_FILE" ] || die "File password mancante: $PROTON_PASS_FILE"
[ -f "$OTP_SECRET_FILE" ] || die "File OTP secret mancante: $OTP_SECRET_FILE"

PROTON_PASS=$(cat "$PROTON_PASS_FILE")

# Stop bridge se in esecuzione
sudo systemctl stop proton-drive-bridge 2>/dev/null || true
pkill -f proton-drive-bridge 2>/dev/null || true
sleep 2

# Rimuovi sessione corrotta
rm -f "${SESSION_DIR}/pdrive-bridge.json"
log "Sessione precedente rimossa"

# Genera codice 2FA
TOTP_CODE=$(generate_totp)
log "Codice 2FA generato"

# Lancia il bridge con expect per automatizzare il 2FA
log "Autenticazione in corso..."

eval "$(dbus-launch --sh-syntax)"
echo "" | gnome-keyring-daemon --unlock --components=secrets 2>/dev/null || true

expect -c "
    set timeout 60
    spawn ${BRIDGE_BIN} --cli \
        --username \"${PROTON_USER}\" \
        --password \"${PROTON_PASS}\" \
        --sessionpassword \"${SESSION_PASSWORD}\" \
        --port ${BRIDGE_PORT}

    expect {
        \"Enter 2FA code:\" {
            send \"${TOTP_CODE}\r\"
            exp_continue
        }
        \"FTP server listening\" {
            sleep 3
        }
        \"Wrong session password\" {
            send \"r\r\"
            exp_continue
        }
        timeout {
            puts \"TIMEOUT\"
            exit 1
        }
        eof {
            puts \"EOF inatteso\"
            exit 1
        }
    }
" 2>&1

# Verifica che la sessione sia stata salvata con vault non vuoto (>1KB)
if [ ! -f "${SESSION_DIR}/pdrive-bridge.json" ]; then
    die "Sessione non salvata dopo login"
fi
SESSION_SIZE=$(wc -c < "${SESSION_DIR}/pdrive-bridge.json")
if [ "$SESSION_SIZE" -lt 1000 ]; then
    die "Sessione salvata ma vault vuoto (${SESSION_SIZE} bytes) — login fallito"
fi
log "Sessione salvata: ${SESSION_SIZE} bytes"

# Uccidi il bridge temporaneo (expect lo ha lanciato in foreground)
pkill -f "proton-drive-bridge.*--port ${BRIDGE_PORT}" 2>/dev/null || true
sleep 2

# Riavvia il service systemd
log "Riavvio bridge via systemd..."
sudo systemctl start proton-drive-bridge
sleep 5

# Verifica finale
if bridge_is_alive; then
    log "Sessione rinnovata con successo. Bridge attivo."
    exit 0
else
    die "Bridge non risponde dopo il refresh"
fi
