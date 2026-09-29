#!/usr/bin/env bash
# =============================================================================
# SYSTEMD HEALTH WATCHDOG
# =============================================================================
# Runs every 5 min via systemd timer (systemd-health-watchdog.timer).
# Detects a "wedged" PID1 (alive but no longer answering systemctl/D-Bus) — see
# the README pitfall 2026-09-11: a kernel Oops during a container
# start/stop can leave systemd stuck without panicking the kernel
# (hence without kdump/automatic reboot) and without any alert for days
# (it happened like that from 11 to 14/09, discovered only from a 502 on Immich).
#
# Sends ONE email when the problem starts, then at most one every hour
# while it persists, and a "resolved" one when it returns to normal.
#
# Does NOT reboot by itself: a forced reboot (reboot -f, the only way when
# systemd is wedged: a normal 'sudo reboot' also goes through PID1 and times
# out) skips the orderly sync/stop of the DBs in the containers (Postgres/
# MariaDB/SQLite) — the decision to do it stays manual.
#
# Log: journalctl -u systemd-health-watchdog / logger -t systemd-health-watchdog
# State: /var/lib/systemd-health-watchdog/
# =============================================================================
set -u

STATE_DIR="/var/lib/systemd-health-watchdog"
STATE_FILE="$STATE_DIR/wedged-since"
LAST_ALERT_FILE="$STATE_DIR/last-alert"
ENV_FILE="/mnt/nas2/docker/.env"
LOG_TAG="systemd-health-watchdog"
REALERT_INTERVAL=3600   # re-alert every 1h while it persists

log() { logger -t "$LOG_TAG" -- "$*"; echo "[$(date +%H:%M:%S)] $*"; }

mkdir -p "$STATE_DIR"

# Send a notification email (uses the shared SMTP from .env, fallback SMART_*;
# same scheme as backup_offsite.sh/proton_cli_backup.sh)
send_alert_email() {
    local subject="$1" body="$2"
    [ -f "$ENV_FILE" ] || { log "WARN: .env non trovato, email non inviata"; return 1; }

    env_get() { grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- | sed -E 's/^"(.*)"$/\1/'; }

    local smtp_host smtp_port smtp_user smtp_pass smtp_from smtp_from_name smtp_to smtp_ssl smtp_tls smtp_url
    smtp_host=$(env_get SMTP_HOST || true); smtp_host=${smtp_host:-$(env_get SMART_SMTP_HOST || true)}
    smtp_port=$(env_get SMTP_PORT || true); smtp_port=${smtp_port:-$(env_get SMART_SMTP_PORT || true)}
    smtp_user=$(env_get SMTP_USERNAME || true); smtp_user=${smtp_user:-$(env_get SMART_SMTP_USERNAME || true)}
    smtp_pass=$(env_get SMTP_PASSWORD || true); smtp_pass=${smtp_pass:-$(env_get SMART_SMTP_PASSWORD || true)}
    smtp_from=$(env_get SMTP_FROM || true); smtp_from=${smtp_from:-$(env_get SMART_SMTP_FROM || true)}
    smtp_from_name=$(env_get SMTP_FROM_NAME || true); smtp_from_name=${smtp_from_name:-$(env_get SMART_SMTP_FROM_NAME || true)}
    smtp_ssl=$(env_get SMTP_SSL || true); smtp_ssl=${smtp_ssl:-$(env_get SMART_SMTP_SSL || true)}
    smtp_tls=$(env_get SMTP_EXPLICIT_TLS || true); smtp_tls=${smtp_tls:-$(env_get SMART_SMTP_EXPLICIT_TLS || true)}
    smtp_to=$(grep '^SMART_ALERT_EMAIL=' "$ENV_FILE" | cut -d= -f2)

    if [ -z "$smtp_host" ] || [ -z "$smtp_to" ]; then
        log "WARN: variabili SMTP incomplete, email non inviata"
        return 1
    fi

    if [ "$smtp_ssl" = "true" ]; then
        smtp_url="smtps://${smtp_host}:${smtp_port}"
    else
        smtp_url="smtp://${smtp_host}:${smtp_port}"
    fi

    local curl_tls=()
    [ "$smtp_ssl" = "true" ] || [ "$smtp_tls" = "true" ] && curl_tls=(--ssl-reqd)

    # Precompute OUTSIDE the heredoc: a default with an apostrophe inside
    # ${var:-...} in a heredoc breaks bash parsing (see the README, Lessons learned).
    local from_name="${smtp_from_name:-REDACTED_BRAND Services}"

    curl -s --max-time 30 --url "$smtp_url" \
        "${curl_tls[@]}" \
        --mail-from "$smtp_from" \
        --mail-rcpt "$smtp_to" \
        --user "${smtp_user}:${smtp_pass}" \
        -T - <<MAILEOF
From: ${from_name} <${smtp_from}>
To: ${smtp_to}
Subject: [REDACTED_HOSTNAME] ${subject}
Content-Type: text/plain; charset=utf-8
Date: $(date -R)

${body}
MAILEOF
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        log "Email inviata: ${subject}"
    else
        log "WARN: invio email fallito (exit ${rc}): ${subject}"
    fi
    return $rc
}

# --- Check -------------------------------------------------------------------
# systemctl is-system-running already returns exit!=0 for "degraded" (normal,
# e.g. a oneshot unit that failed once) — that is NOT wedged. The specific
# signal of a stuck PID1 is the bus activation timeout/error.
OUT=$(timeout 8 systemctl is-system-running 2>&1)
RC=$?

if [[ $RC -eq 124 ]] || echo "$OUT" | grep -qi "Failed to activate service 'org.freedesktop.systemd1'\|timed out"; then
    NOW=$(date +%s)
    if [[ -f "$STATE_FILE" ]]; then
        SINCE=$(cat "$STATE_FILE")
        LAST_ALERT=$(cat "$LAST_ALERT_FILE" 2>/dev/null || echo 0)
        if (( NOW - LAST_ALERT < REALERT_INTERVAL )); then
            log "systemd ancora wedged (da $(date -d @"$SINCE" '+%d/%m %H:%M')), alert gia' inviato di recente"
            exit 0
        fi
    else
        SINCE=$NOW
        echo "$SINCE" > "$STATE_FILE"
        log "NUOVO: systemd (PID1) sembra wedged — $OUT"
    fi
    echo "$NOW" > "$LAST_ALERT_FILE"
    send_alert_email "ATTENZIONE: systemd wedged su $(hostname)" \
"systemd (PID1) su $(hostname) non risponde a systemctl/D-Bus da $(date -d @"$SINCE" '+%d/%m/%Y %H:%M').

Sintomo: ${OUT}

Effetto pratico: Docker non riesce piu' a (ri)avviare container che si
fermano o crashano (cgroup driver systemd bloccato) — i servizi gia' in
esecuzione continuano a funzionare, ma qualsiasi crash da questo momento in
poi NON si riprendera' da solo.

Fix noto (vedi README, sezione Pitfall, 'systemd wedged'): serve un riavvio.
'sudo reboot' normale NON funziona (passa anch'esso da PID1) — serve
'sudo reboot -f' / 'sudo systemctl reboot -ff' (bypassa systemd, salta la
sync/stop ordinato dei DB nei container) oppure un riavvio fisico/da console
locale.

Verifica: journalctl -k | grep 'Transport endpoint is not connected'" \
        || true
else
    if [[ -f "$STATE_FILE" ]]; then
        SINCE=$(cat "$STATE_FILE")
        log "systemd tornato responsivo (era wedged da $(date -d @"$SINCE" '+%d/%m %H:%M'))"
        send_alert_email "RISOLTO: systemd tornato responsivo su $(hostname)" \
"systemd (PID1) su $(hostname) ha ripreso a rispondere normalmente.
Era rimasto wedged da $(date -d @"$SINCE" '+%d/%m/%Y %H:%M') a $(date '+%d/%m/%Y %H:%M')." \
            || true
        rm -f "$STATE_FILE" "$LAST_ALERT_FILE"
    fi
fi
