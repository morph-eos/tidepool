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
# Alert thresholds (configurable via env)
: "${SMART_TEMP_WARN:=45}"       # °C — temperature warning (longevity degrades above 40°C)
: "${SMART_TEMP_CRIT:=50}"       # °C — temperature critical
: "${SMART_REALLOCATED_WARN:=1}" # reallocated sectors (any = problem)
: "${SMART_PENDING_WARN:=1}"     # pending sectors (any = problem)
: "${SMART_CRC_WARN:=1}"         # UDMA CRC errors (point to the cable/USB enclosure)
: "${SMART_CMD_TIMEOUT_WARN:=1}" # command timeout (imminent USB disconnect)
: "${SMART_SPIN_RETRY_WARN:=1}"  # spin retry (power/motor)

LOG_DIR=/var/log/smart
LOG_FILE="$LOG_DIR/smartcheck.log"
mkdir -p "$LOG_DIR"

# Log to stderr (for docker logs) and to a persistent file
log() {
    printf '%s\n' "$*" >> "$LOG_FILE"
    printf '%s\n' "$*" >&2
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

    # Read all SMART attributes once
    full=$(smartctl -d sat -a "$dev" 2>&1)

    # Helper: extract the first RAW value (field 10) for an attribute ID
    # Filter only SMART rows (with the hex flag in column 3) to avoid contamination from self-test
    get_raw() {
        echo "$full" | awk -v id="$1" '$1 == id && $3 ~ /^0x/ {print $10}'
    }

    # --- Overall health ---
    health=$(echo "$full" | grep "overall-health" | tr -d '\r')
    log "[$(date)] $dev: $health"
    if echo "$health" | grep -qi "FAILED"; then
        critical="$critical\n[CRITICO] Salute generale: FAILED"
    fi

    # --- Temperature (ID 194 preferred, fallback to 190) ---
    # Field 10 holds the numeric value (e.g. "47" from "47 (0 19 0 0 0)")
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

    # --- Reallocated sectors (ID 5) ---
    val=$(get_raw 5)
    if [ -n "$val" ] && [ "$val" -ge "$SMART_REALLOCATED_WARN" ] 2>/dev/null; then
        critical="$critical\n[CRITICO] Reallocated sectors: $val"
    fi

    # --- Spin Retry Count (ID 10) — power/motor ---
    val=$(get_raw 10)
    if [ -n "$val" ] && [ "$val" -ge "$SMART_SPIN_RETRY_WARN" ] 2>/dev/null; then
        warnings="$warnings\n[WARNING] Spin retry count: $val — verificare alimentazione"
    fi

    # --- Reported Uncorrectable Errors (ID 187) ---
    val=$(get_raw 187)
    if [ -n "$val" ] && [ "$val" -gt 0 ] 2>/dev/null; then
        critical="$critical\n[CRITICO] Reported uncorrectable errors: $val"
    fi

    # --- Command Timeout (ID 188) — essential for USB ---
    # REDACTED_DISK_VENDOR raw is 64-bit: bits 0-15 = timeout count. Use awk for the masking
    # (busybox sh may not handle numbers >2^32)
    raw188=$(get_raw 188)
    if [ -n "$raw188" ]; then
        val=$(echo "$raw188" | awk '{v=$1+0; if(v>65535){printf "%d",v%65536}else{print v}}')
        if [ "$val" -ge "$SMART_CMD_TIMEOUT_WARN" ] 2>/dev/null; then
            warnings="$warnings\n[WARNING] Command timeout count: $val (raw: $raw188) — rischio disconnessione USB"
        fi
    fi

    # --- Pending sectors (ID 197) ---
    val=$(get_raw 197)
    if [ -n "$val" ] && [ "$val" -ge "$SMART_PENDING_WARN" ] 2>/dev/null; then
        critical="$critical\n[CRITICO] Current pending sectors: $val"
    fi

    # --- Offline uncorrectable sectors (ID 198) ---
    val=$(get_raw 198)
    if [ -n "$val" ] && [ "$val" -gt 0 ] 2>/dev/null; then
        critical="$critical\n[CRITICO] Offline uncorrectable sectors: $val"
    fi

    # --- UDMA CRC errors (ID 199) — cable/USB enclosure ---
    val=$(get_raw 199)
    if [ -n "$val" ] && [ "$val" -ge "$SMART_CRC_WARN" ] 2>/dev/null; then
        warnings="$warnings\n[WARNING] UDMA CRC errors: $val — verificare cavo/enclosure USB"
    fi

    # --- Multi-Zone Error Rate (ID 200) ---
    val=$(get_raw 200)
    if [ -n "$val" ] && [ "$val" -gt 0 ] 2>/dev/null; then
        warnings="$warnings\n[WARNING] Multi-zone error rate: $val"
    fi

    # --- Power On Hours (informational) + summary log ---
    poh=$(get_raw 9)
    # Recompute the masked command timeout for the summary
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

    # Return messages for email
    printf '%b' "${critical}${warnings}"
}

apk add --no-cache smartmontools msmtp ca-certificates >/dev/null 2>&1
write_msmtp_config || true

log "[$(date)] === smartcheck avviato (dispositivi: $SMART_DEVICES, intervallo: $SMART_CHECK_INTERVAL) ==="

# Startup notification to verify SMTP
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
