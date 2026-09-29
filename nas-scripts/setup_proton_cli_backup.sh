#!/usr/bin/env bash
# =============================================================================
# Idempotent setup of the backup via the OFFICIAL Proton Drive CLI (replacement for the FTP bridge).
# RUN AS REDACTED_HOSTNAME (per-user Proton session, in libsecret).
#  - installs/updates /usr/local/bin/proton-drive (latest version)
#  - creates the log writable by REDACTED_HOSTNAME
#  - installs and enables the systemd USER timer (daily mirror 03:30)
# One-time LOGIN (monitor attached):  proton-drive auth login
# The USER timer inherits D-Bus+keyring from REDACTED_HOSTNAME's autologin session.
# =============================================================================
set -uo pipefail
TARGET_USER=REDACTED_HOSTNAME
if [ "$(id -un)" != "$TARGET_USER" ]; then
    echo "Esegui come $TARGET_USER (NON root): sudo -u $TARGET_USER $0"; exit 1
fi
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
BIN=/usr/local/bin/proton-drive
MARKER=/usr/local/lib/proton-drive.version
LOG=/var/log/proton-cli-backup.log
UDIR="$HOME/.config/systemd/user"
INDEX=https://proton.me/download/drive/cli/index.html
case "$(uname -m)" in
  x86_64) ARCH=linux-x64;; aarch64|arm64) ARCH=linux-arm64;;
  *) echo "ERRORE: arch $(uname -m) non supportata"; exit 1;;
esac
URL=$(curl -sL --max-time 30 "$INDEX" 2>/dev/null | grep -oE "https://proton.me/download/drive/cli/[0-9.]+/${ARCH}/proton-drive" | sort -V | tail -1)
[ -n "$URL" ] || { echo "ERRORE: URL download non trovato"; exit 1; }
VER=$(echo "$URL" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
CUR=$(cat "$MARKER" 2>/dev/null || true)
if [ -x "$BIN" ] && [ "$CUR" = "$VER" ]; then
    echo "[1] proton-drive gia' a $VER (no-op)"
else
    tmp=$(mktemp); curl -fsSL --max-time 240 -o "$tmp" "$URL" || { echo "ERRORE download"; rm -f "$tmp"; exit 1; }
    sudo install -m 0755 "$tmp" "$BIN"; rm -f "$tmp"; echo "$VER" | sudo tee "$MARKER" >/dev/null
    echo "[1] proton-drive installato/aggiornato a $VER (era: ${CUR:-assente})"
fi
# Log writable by REDACTED_HOSTNAME
if [ ! -w "$LOG" ]; then sudo touch "$LOG" && sudo chown "$TARGET_USER":"$TARGET_USER" "$LOG" && echo "[2] log pronto"; else echo "[2] log gia' pronto"; fi
# systemd USER timer
mkdir -p "$UDIR"
cat > "$UDIR/proton-cli-backup.service" <<UNIT
[Unit]
Description=Mirror repo Borg offsite -> Proton Drive (CLI ufficiale)
After=default.target

[Service]
Type=oneshot
ExecStart=/mnt/nas2/nas-scripts/proton_cli_backup.sh
UNIT
cat > "$UDIR/proton-cli-backup.timer" <<UNIT
[Unit]
Description=Mirror Proton Drive giornaliero (CLI ufficiale)

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
UNIT
systemctl --user daemon-reload 2>/dev/null || true
if systemctl --user enable --now proton-cli-backup.timer 2>/dev/null; then
    echo "[3] systemd user timer abilitato (prossimo: $(systemctl --user list-timers proton-cli-backup.timer --no-pager 2>/dev/null | awk 'NR==2{print $1,$2}'))"
else
    echo "[3] WARN: impossibile abilitare il timer (sessione utente non raggiungibile da qui?)"
fi
# Auth status
if "$BIN" filesystem list / >/dev/null 2>&1; then echo "[4] Login: AUTENTICATO"; else echo "[4] Login: NON autenticato -> 'proton-drive auth login'"; fi
echo "ESITO: setup proton-drive CLI completato"
