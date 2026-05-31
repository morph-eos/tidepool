#!/usr/bin/env bash
# =============================================================================
# WIFI WATCHDOG
# =============================================================================
# Esegue ogni 60s via systemd timer (wifi-watchdog.timer).
# Se REDACTED_WIFI_IFACE non ha un IPv4 valido o non riesce a pingare il gateway, forza:
#   1) rescan WiFi
#   2) disconnect + reconnect del profilo
# Risolve il caso in cui NetworkManager va in stato 'failed (no-secrets)' o
# 'disconnected' dopo che il modem si riavvia di notte e non riprova piu'.
# Log: journalctl -u wifi-watchdog.service
# =============================================================================
set -u

IFACE="REDACTED_WIFI_IFACE"
PROFILE="REDACTED_WIFI_SSID"
GATEWAY="192.0.2.1"
LOG_TAG="wifi-watchdog"

log() { logger -t "$LOG_TAG" -- "$*"; echo "[$(date +%H:%M:%S)] $*"; }

# Skip se Ethernet attiva con IP (preferiamo cavo)
if ip -4 addr show REDACTED_ETH_IFACE 2>/dev/null | grep -q 'inet '; then
    exit 0
fi

# Se il device non c'e' (driver crashato), prova rfkill unblock
if ! ip link show "$IFACE" >/dev/null 2>&1; then
    log "Device $IFACE assente, tentativo rfkill unblock"
    rfkill unblock wifi 2>/dev/null
    exit 0
fi

# Se NM device state e' connected E ha un IP, controlliamo il gateway
STATE=$(nmcli -t -f GENERAL.STATE dev show "$IFACE" 2>/dev/null | cut -d: -f2)
HAS_IP=$(ip -4 addr show "$IFACE" 2>/dev/null | grep -c 'inet ')

if [[ "$STATE" == "100 (connected)" && "$HAS_IP" -gt 0 ]]; then
    # Ping gateway con timeout 3s, 2 tentativi
    if ping -c 2 -W 3 -I "$IFACE" "$GATEWAY" >/dev/null 2>&1; then
        exit 0  # tutto OK
    fi
    log "WARN: connesso ma gateway $GATEWAY non risponde, forzo riconnessione"
fi

[[ "$STATE" != "100 (connected)" ]] && log "Stato $IFACE: $STATE — riconnessione"

# Recovery: disconnect + scan + reconnect
nmcli device disconnect "$IFACE" >/dev/null 2>&1 || true
sleep 2
nmcli device wifi rescan ifname "$IFACE" >/dev/null 2>&1 || true
sleep 3

if nmcli connection up "$PROFILE" ifname "$IFACE" >/dev/null 2>&1; then
    log "Riconnessione OK"
else
    log "ERROR: nmcli up fallito (codice $?)"
    # Ultima risorsa: ricarica connessioni e riavvia NM
    nmcli connection reload >/dev/null 2>&1 || true
fi
