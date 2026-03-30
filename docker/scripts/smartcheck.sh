#!/bin/sh
set -eu

: "${SMART_DEVICES:=/dev/smartcheck-nas2 /dev/smartcheck-nas}"
: "${SMART_CHECK_INTERVAL:=12h}"
: "${SMART_ALERT_EMAIL:=}"
: "${SMTP_HOST:=}"
: "${SMTP_PORT:=}"
: "${SMTP_USERNAME:=}"
: "${SMTP_PASSWORD:=}"
: "${SMTP_FROM:=}"
: "${SMTP_FROM_NAME:=SMART Monitor}"
: "${SMTP_SSL:=false}"
: "${SMTP_EXPLICIT_TLS:=false}"
# Soglie di allerta (configurabili via env)
: "${SMART_TEMP_WARN:=45}"       # °C — warning temperatura (longevità degrada >40°C)
: "${SMART_TEMP_CRIT:=50}"       # °C — critico temperatura
: "${SMART_REALLOCATED_WARN:=1}" # settori ricollocati (qualsiasi = problema)
: "${SMART_PENDING_WARN:=1}"     # settori pending (qualsiasi = problema)
: "${SMART_CRC_WARN:=1}"         # errori UDMA CRC (indicano cavo/enclosure USB)
: "${SMART_CMD_TIMEOUT_WARN:=1}" # command timeout (USB disconnect imminente)
: "${SMART_SPIN_RETRY_WARN:=1}"  # spin retry (alimentazione/motore)

LOG_DIR=/var/log/smart
LOG_FILE="$LOG_DIR/smartcheck.log"
mkdir -p "$LOG_DIR"

# Log su stdout (per docker logs) e su file persistente
log() {
    printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

write_msmtp_config() {
    if [ -z "$SMTP_HOST" ] || [ -z "$SMTP_PORT" ] || [ -z "$SMTP_USERNAME" ] || [ -z "$SMTP_PASSWORD" ] || [ -z "$SMTP_FROM" ]; then
        log "SMTP non configurato, email disabilitate"
        return 1
    fi

    cat > /etc/msmtprc <<EOF
defaults
auth on
tls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile /var/log/smart/msmtp.log

account default
host $SMTP_HOST
port $SMTP_PORT
from $SMTP_FROM
user $SMTP_USERNAME
password $SMTP_PASSWORD
EOF

    if [ "$SMTP_SSL" = "true" ]; then
        echo "tls_starttls off" >> /etc/msmtprc
    elif [ "$SMTP_EXPLICIT_TLS" = "true" ]; then
        echo "tls_starttls on" >> /etc/msmtprc
    else
        echo "tls off" >> /etc/msmtprc
    fi

    chmod 600 /etc/msmtprc
    return 0
}

send_alert() {
    subject="$1"
    body="$2"

    if [ -z "$SMART_ALERT_EMAIL" ]; then
        log "SMART_ALERT_EMAIL non impostata, skip invio"
        return 0
    fi

    printf "Subject: %s\nFrom: %s\nTo: %s\n\n%s\n" \
        "$subject" "$SMTP_FROM_NAME <$SMTP_FROM>" "$SMART_ALERT_EMAIL" "$body" | \
        msmtp -a default "$SMART_ALERT_EMAIL"
}

check_device() {
    dev="$1"
    warnings=""
    critical=""

    if [ ! -e "$dev" ]; then
        log "[$(date)] ATTENZIONE: dispositivo non trovato: $dev"
        echo "[CRITICO] Dispositivo non trovato: $dev"
        return 0
    fi

    # Legge tutti gli attributi SMART una volta sola
    full=$(smartctl -d sat -a "$dev" 2>&1)

    # Helper: estrae il primo valore RAW (campo 10) per un attributo ID
    # Filtra solo righe SMART (con flag hex in colonna 3) per evitare contaminazione da self-test
    get_raw() {
        echo "$full" | awk -v id="$1" '$1 == id && $3 ~ /^0x/ {print $10}'
    }

    # --- Salute generale ---
    health=$(echo "$full" | grep "overall-health" | tr -d '\r')
    log "[$(date)] $dev: $health"
    if echo "$health" | grep -qi "FAILED"; then
        critical="$critical\n[CRITICO] Salute generale: FAILED"
    fi

    # --- Temperatura (ID 194 preferito, fallback a 190) ---
    # Il campo 10 contiene il valore numerico (es: "47" da "47 (0 19 0 0 0)")
    temp=$(get_raw 194)
    if [ -z "$temp" ] || ! [ "$temp" -eq "$temp" ] 2>/dev/null; then
        temp=$(get_raw 190)
    fi
    if [ -n "$temp" ] && [ "$temp" -eq "$temp" ] 2>/dev/null; then
        if [ "$temp" -ge "$SMART_TEMP_CRIT" ]; then
            critical="$critical\n[CRITICO] Temperatura: ${temp}°C (soglia: ${SMART_TEMP_CRIT}°C)"
        elif [ "$temp" -ge "$SMART_TEMP_WARN" ]; then
            warnings="$warnings\n[WARNING] Temperatura: ${temp}°C (soglia: ${SMART_TEMP_WARN}°C)"
        fi
    fi

    # --- Settori ricollocati (ID 5) ---
    val=$(get_raw 5)
    if [ -n "$val" ] && [ "$val" -ge "$SMART_REALLOCATED_WARN" ] 2>/dev/null; then
        critical="$critical\n[CRITICO] Reallocated sectors: $val"
    fi

    # --- Spin Retry Count (ID 10) — alimentazione/motore ---
    val=$(get_raw 10)
    if [ -n "$val" ] && [ "$val" -ge "$SMART_SPIN_RETRY_WARN" ] 2>/dev/null; then
        warnings="$warnings\n[WARNING] Spin retry count: $val — verificare alimentazione"
    fi

    # --- Reported Uncorrectable Errors (ID 187) ---
    val=$(get_raw 187)
    if [ -n "$val" ] && [ "$val" -gt 0 ] 2>/dev/null; then
        critical="$critical\n[CRITICO] Reported uncorrectable errors: $val"
    fi

    # --- Command Timeout (ID 188) — fondamentale per USB ---
    # REDACTED_DISK_VENDOR raw è 64bit: bits 0-15 = timeout count. Usa awk per il masking
    # (busybox sh potrebbe non gestire numeri >2^32)
    raw188=$(get_raw 188)
    if [ -n "$raw188" ]; then
        val=$(echo "$raw188" | awk '{v=$1+0; if(v>65535){printf "%d",v%65536}else{print v}}')
        if [ "$val" -ge "$SMART_CMD_TIMEOUT_WARN" ] 2>/dev/null; then
            warnings="$warnings\n[WARNING] Command timeout count: $val (raw: $raw188) — rischio disconnessione USB"
        fi
    fi

    # --- Settori pending (ID 197) ---
    val=$(get_raw 197)
    if [ -n "$val" ] && [ "$val" -ge "$SMART_PENDING_WARN" ] 2>/dev/null; then
        critical="$critical\n[CRITICO] Current pending sectors: $val"
    fi

    # --- Settori uncorrectable offline (ID 198) ---
    val=$(get_raw 198)
    if [ -n "$val" ] && [ "$val" -gt 0 ] 2>/dev/null; then
        critical="$critical\n[CRITICO] Offline uncorrectable sectors: $val"
    fi

    # --- UDMA CRC errors (ID 199) — cavo/enclosure USB ---
    val=$(get_raw 199)
    if [ -n "$val" ] && [ "$val" -ge "$SMART_CRC_WARN" ] 2>/dev/null; then
        warnings="$warnings\n[WARNING] UDMA CRC errors: $val — verificare cavo/enclosure USB"
    fi

    # --- Multi-Zone Error Rate (ID 200) ---
    val=$(get_raw 200)
    if [ -n "$val" ] && [ "$val" -gt 0 ] 2>/dev/null; then
        warnings="$warnings\n[WARNING] Multi-zone error rate: $val"
    fi

    # --- Power On Hours (informativo) + log riepilogo ---
    poh=$(get_raw 9)
    # Ricalcola command timeout mascherato per il riepilogo
    _ct_raw=$(get_raw 188)
    _ct=$(echo "${_ct_raw:-0}" | awk '{v=$1+0; if(v>65535){printf "%d",v%65536}else{print v}}')
    log "[$(date)] $dev: temp=${temp:-?}°C power_on=${poh:-?}h reallocated=$(get_raw 5) pending=$(get_raw 197) crc=$(get_raw 199) cmd_timeout=${_ct} uncorrect=$(get_raw 187) offline_uncorr=$(get_raw 198) spin_retry=$(get_raw 10) multizone=$(get_raw 200)"

    # Log warnings/critical
    if [ -n "$critical" ]; then
        log "[$(date)] $dev CRITICAL: $(printf '%b' "$critical" | tr '\n' ' ')"
    fi
    if [ -n "$warnings" ]; then
        log "[$(date)] $dev WARNING: $(printf '%b' "$warnings" | tr '\n' ' ')"
    fi

    # Restituisce messaggi per email
    printf '%b' "${critical}${warnings}"
}

apk add --no-cache smartmontools msmtp ca-certificates >/dev/null 2>&1
write_msmtp_config || true

log "[$(date)] === smartcheck avviato (dispositivi: $SMART_DEVICES, intervallo: $SMART_CHECK_INTERVAL) ==="

# Notifica avvio per verificare SMTP
send_alert "[SMART] Servizio avviato" "Il container smartcheck è stato avviato correttamente su $(hostname) alle $(date)."

while true; do
    alerts=""
    for dev in $SMART_DEVICES; do
        result=$(check_device "$dev")
        if [ -n "$result" ]; then
            alerts="$alerts\n==== $dev ====\n$result\n"
        fi
    done

    if [ -n "$alerts" ]; then
        log "[$(date)] ALERT: anomalie rilevate, invio email..."
        send_alert "[SMART] Anomalie rilevate su $(hostname)" "$(printf '%b' "$alerts")"
    else
        log "[$(date)] Tutti i dischi OK."
    fi

    sleep "$SMART_CHECK_INTERVAL"
done
