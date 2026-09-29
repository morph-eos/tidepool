#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# SETUP FAIL2BAN + SSH HARDENING
# =============================================================================
# - Disabilita autenticazione SSH con password (solo chiavi)
# - Installa e configura fail2ban: ban dopo 3 tentativi falliti
# - Idempotente: può essere rieseguito senza problemi
#
# Uso:
#   sudo bash /mnt/nas2/nas-scripts/setup_fail2ban.sh install
#   sudo bash /mnt/nas2/nas-scripts/setup_fail2ban.sh uninstall
#   sudo bash /mnt/nas2/nas-scripts/setup_fail2ban.sh status
# =============================================================================

# Colori
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[FAIL2BAN]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

# Prefisso 01-: in sshd_config.d per ogni direttiva vince la PRIMA occorrenza (ordine alfabetico)
SSH_HARDENING_CONF="/etc/ssh/sshd_config.d/01-hardening.conf"
SSH_HARDENING_LEGACY="/etc/ssh/sshd_config.d/99-hardening.conf"
FAIL2BAN_JAIL="/etc/fail2ban/jail.d/sshd.conf"
# Porta su cui ascolta sshd (impostata fuori da questo script). Con Ubuntu 24.04 e
# ssh.socket va cambiata nel drop-in del socket, non solo con "Port" in sshd_config.
SSH_PORT="${SSH_PORT:-2222}"

# --- SSH Hardening -----------------------------------------------------------

harden_ssh() {
    log "Hardening SSH..."

    rm -f "$SSH_HARDENING_LEGACY"
    cat > "$SSH_HARDENING_CONF" <<'SSHCONF'
# SSH Hardening — gestito da setup_fail2ban.sh
PasswordAuthentication no
PermitRootLogin prohibit-password
MaxAuthTries 3
SSHCONF

    # Verifica config valida prima di ricaricare
    if sshd -t 2>/dev/null; then
        systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null
        log "SSH: password disabilitata, solo chiavi, max 3 tentativi"
    else
        rm -f "$SSH_HARDENING_CONF"
        die "Config SSH invalida — rollback effettuato"
    fi
}

# --- Fail2ban ----------------------------------------------------------------

install_fail2ban() {
    log "Installazione fail2ban..."

    if ! command -v fail2ban-server &>/dev/null; then
        apt-get update -qq
        apt-get install -y -qq fail2ban
        log "fail2ban installato"
    else
        log "fail2ban già installato"
    fi

    # Jail SSH: ban dopo 3 tentativi in 10 minuti, ban 1 ora, recidivi 1 settimana
    cat > "$FAIL2BAN_JAIL" <<JAIL
# SSH jail — gestito da setup_fail2ban.sh
# Ban dopo 3 tentativi falliti in 10 minuti
[sshd]
enabled  = true
mode     = aggressive
port     = ${SSH_PORT}
filter   = sshd[mode=aggressive]
backend  = systemd
maxretry = 3
findtime = 600
bantime  = 3600
banaction = iptables-multiport

# Recidivi: chi viene bannato 3+ volte in 12 ore → ban 1 settimana
[recidive]
enabled  = true
filter   = recidive
logpath  = /var/log/fail2ban.log
maxretry = 3
findtime = 43200
bantime  = 604800
banaction = iptables-multiport
JAIL

    systemctl enable --now fail2ban
    systemctl restart fail2ban
    log "fail2ban attivo: ban dopo 3 tentativi (1h), recidivi (1 settimana)"
}

# --- Status ------------------------------------------------------------------

show_status() {
    echo ""
    echo "=== SSH Hardening ==="
    if [ -f "$SSH_HARDENING_CONF" ]; then
        echo -e "  Config: ${GREEN}attivo${NC} ($SSH_HARDENING_CONF)"
        sshd -T 2>/dev/null | grep -iE "passwordauthentication|permitrootlogin|maxauthtries" | sed 's/^/  /'
    else
        echo -e "  Config: ${RED}non configurato${NC}"
    fi
    echo ""

    echo "=== Fail2ban ==="
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo -e "  Servizio: ${GREEN}attivo${NC}"
        fail2ban-client status sshd 2>/dev/null | sed 's/^/  /' || echo "  (jail sshd non trovata)"
        echo ""
        local recidive_status
        recidive_status=$(fail2ban-client status recidive 2>/dev/null | grep "Currently banned" || echo "")
        [ -n "$recidive_status" ] && echo "  Recidivi: $recidive_status"
    else
        echo -e "  Servizio: ${RED}inattivo${NC}"
    fi
    echo ""
}

# --- Uninstall ---------------------------------------------------------------

do_uninstall() {
    warn "Rimozione fail2ban e ripristino SSH..."

    # Rimuovi hardening SSH
    rm -f "$SSH_HARDENING_CONF" "$SSH_HARDENING_LEGACY"
    if sshd -t 2>/dev/null; then
        systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null
    fi
    log "SSH: config hardening rimossa (default ripristinato)"

    # Rimuovi fail2ban
    rm -f "$FAIL2BAN_JAIL"
    systemctl disable --now fail2ban 2>/dev/null || true
    apt-get remove -y fail2ban 2>/dev/null || true
    log "fail2ban rimosso"
}

# --- Main --------------------------------------------------------------------

case "${1:-}" in
    install)
        [ "$(id -u)" -eq 0 ] || die "Esegui come root: sudo $0 install"
        harden_ssh
        install_fail2ban
        echo ""
        show_status
        log "Setup completato."
        ;;
    uninstall)
        [ "$(id -u)" -eq 0 ] || die "Esegui come root: sudo $0 uninstall"
        do_uninstall
        ;;
    status)
        show_status
        ;;
    *)
        echo "Uso: $0 {install|uninstall|status}"
        echo ""
        echo "  install   — Hardening SSH + fail2ban"
        echo "  uninstall — Rimuove tutto (ripristina default)"
        echo "  status    — Mostra stato"
        exit 1
        ;;
esac
