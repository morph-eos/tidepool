#!/usr/bin/env bash
# =============================================================================
# WIFI WATCHDOG
# =============================================================================
# Runs every 60s via systemd timer (wifi-watchdog.timer).
# If REDACTED_WIFI_IFACE has no valid IPv4 or cannot ping the gateway, it forces:
#   1) WiFi rescan
#   2) profile disconnect + reconnect
# Solves the case where NetworkManager goes into the 'failed (no-secrets)' or
# 'disconnected' state after the modem reboots at night and does not retry anymore.
# Log: journalctl -u wifi-watchdog.service
# =============================================================================
set -u

IFACE="REDACTED_WIFI_IFACE"
PROFILE="REDACTED_WIFI_SSID"
GATEWAY="192.0.2.1"
LOG_TAG="wifi-watchdog"

log() { logger -t "$LOG_TAG" -- "$*"; echo "[$(date +%H:%M:%S)] $*"; }

# Skip if Ethernet is active with an IP (we prefer the cable)
if ip -4 addr show REDACTED_ETH_IFACE 2>/dev/null | grep -q 'inet '; then
    exit 0
fi

# If the device is not there (driver crashed), try rfkill unblock
if ! ip link show "$IFACE" >/dev/null 2>&1; then
    log "Device $IFACE assente, tentativo rfkill unblock"
    rfkill unblock wifi 2>/dev/null
    exit 0
fi

# If the NM device state is connected AND it has an IP, check the gateway
STATE=$(nmcli -t -f GENERAL.STATE dev show "$IFACE" 2>/dev/null | cut -d: -f2)
HAS_IP=$(ip -4 addr show "$IFACE" 2>/dev/null | grep -c 'inet ')

if [[ "$STATE" == "100 (connected)" && "$HAS_IP" -gt 0 ]]; then
    # Ping the gateway with a 3s timeout, 2 attempts
    if ping -c 2 -W 3 -I "$IFACE" "$GATEWAY" >/dev/null 2>&1; then
        exit 0  # all OK
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
    # Last resort: reload connections and restart NM
    nmcli connection reload >/dev/null 2>&1 || true
fi
