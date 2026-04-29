#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# SETUP INCUS — VM Manager con UI Web + SSH proxy automatico
# =============================================================================
# Installa e configura Incus + UI Canonical per gestione VM via browser.
# Pensato per Ubuntu 24.04, compatibile con Docker coesistente.
#
# Funzionalità:
#   - Incus con storage su directory (zero repartition)
#   - UI web su incus.REDACTED_DOMAIN (via nginx reverse proxy)
#   - SSH proxy automatico: porta 2201-2299 per VM via socat + systemd
#   - Cloud-init: SSH + chiave host iniettata automaticamente nelle VM
#   - iptables persistence per coesistenza Docker/Incus
#   - Swap ampliato a 16 GB su SSD per supportare più VM
#   - zram per compressione RAM
#
# Uso:
#   sudo bash /mnt/nas2/nas-scripts/setup_incus.sh install
#   sudo bash /mnt/nas2/nas-scripts/setup_incus.sh uninstall
#   sudo bash /mnt/nas2/nas-scripts/setup_incus.sh status
#   sudo bash /mnt/nas2/nas-scripts/setup_incus.sh export   # esporta config per restore
#   sudo bash /mnt/nas2/nas-scripts/setup_incus.sh restore  # ripristina su nuovo server
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INCUS_STORAGE="/mnt/nas2/incus-vms"
INCUS_BACKUP_DIR="/mnt/nas2/incus-backup"
NGINX_CONF="/mnt/nas2/docker/data/nginx/nginx.conf"
PROXY_DIR="/mnt/nas2/incus-vms/port-proxy"
PROXY_STATE="/mnt/nas2/incus-vms/port-proxy-state.txt"
PORT_MAP="/mnt/nas2/incus-vms/port-map.txt"
UI_DOMAIN="incus.REDACTED_DOMAIN"
SWAP_SIZE="16G"
SWAP_FILE="/swap.img"
ZRAM_SIZE_MB=4096
INCUS_USER="REDACTED_HOSTNAME"
SSH_KEY_FILE="/home/${INCUS_USER}/.ssh/id_ed25519.pub"

# Colori
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INCUS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

# --- Funzioni di installazione -----------------------------------------------

install_incus() {
    log "Installazione Incus..."

    # Repo ufficiale Incus (zabbly)
    if ! command -v incus &>/dev/null; then
        log "Aggiunta repository zabbly/incus..."
        curl -fsSL https://pkgs.zabbly.com/key.asc | gpg --dearmor -o /etc/apt/keyrings/zabbly.gpg
        cat > /etc/apt/sources.list.d/zabbly-incus-stable.sources <<REPO
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/zabbly.gpg
REPO
        apt-get update
        apt-get install -y incus incus-ui-canonical
        log "Incus installato"
    else
        log "Incus già installato: $(incus --version)"
    fi

    # Aggiungi utente al gruppo incus-admin
    if ! groups "$INCUS_USER" | grep -q incus-admin; then
        usermod -aG incus-admin "$INCUS_USER"
        log "Utente $INCUS_USER aggiunto a incus-admin"
    fi
}

setup_swap() {
    log "Configurazione swap ($SWAP_SIZE) e zram..."

    # Swap file
    local current_swap
    current_swap=$(swapon --show=SIZE --noheadings --bytes 2>/dev/null | head -1)
    local target_bytes=$((16 * 1024 * 1024 * 1024))

    if [ -f "$SWAP_FILE" ] && [ "${current_swap:-0}" -lt "$target_bytes" ] 2>/dev/null; then
        log "Ampliamento swap a $SWAP_SIZE..."
        swapoff "$SWAP_FILE" 2>/dev/null || true
        fallocate -l "$SWAP_SIZE" "$SWAP_FILE"
        chmod 600 "$SWAP_FILE"
        mkswap "$SWAP_FILE"
        swapon "$SWAP_FILE"
        log "Swap ampliato a $SWAP_SIZE"
    elif [ ! -f "$SWAP_FILE" ]; then
        log "Creazione swap $SWAP_SIZE..."
        fallocate -l "$SWAP_SIZE" "$SWAP_FILE"
        chmod 600 "$SWAP_FILE"
        mkswap "$SWAP_FILE"
        swapon "$SWAP_FILE"
        # Assicura fstab
        if ! grep -q "$SWAP_FILE" /etc/fstab; then
            echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
        fi
        log "Swap creato"
    else
        log "Swap già configurato a $SWAP_SIZE"
    fi

    # zram
    if ! lsmod | grep -q zram; then
        log "Configurazione zram ($ZRAM_SIZE_MB MB)..."
        apt-get install -y zram-tools 2>/dev/null || true
        cat > /etc/default/zramswap <<ZRAM
ALGO=zstd
PERCENT=25
PRIORITY=100
ZRAM
        systemctl enable --now zramswap 2>/dev/null || true
        log "zram configurato"
    else
        log "zram già attivo"
    fi

    # Swappiness più bassa — preferisci RAM, usa swap solo sotto pressione
    sysctl -w vm.swappiness=30 >/dev/null
    grep -q "vm.swappiness" /etc/sysctl.d/99-vm.conf 2>/dev/null || \
        echo "vm.swappiness=30" > /etc/sysctl.d/99-vm.conf
}

configure_incus() {
    log "Configurazione Incus..."

    # Storage directory
    mkdir -p "$INCUS_STORAGE"

    # Preseed config (non-interattivo)
    cat <<PRESEED | incus admin init --preseed
config:
  core.https_address: 0.0.0.0:8443
networks:
  - name: incusbr0
    type: bridge
    config:
      ipv4.address: 10.100.0.1/24
      ipv4.nat: "true"
      ipv6.address: none
      dns.domain: vm.internal
storage_pools:
  - name: default
    driver: dir
    config:
      source: ${INCUS_STORAGE}
profiles:
  - name: default
    config:
      limits.cpu: "2"
      limits.memory: 2GB
    devices:
      root:
        path: /
        pool: default
        size: 20GB
        type: disk
      eth0:
        name: eth0
        network: incusbr0
        type: nic
PRESEED

    # Cloud-init: crea utente vm-admin uniforme (funziona su Ubuntu, Rocky, Debian, etc.)
    if [ -f "$SSH_KEY_FILE" ]; then
        local pubkey
        pubkey=$(cat "$SSH_KEY_FILE")
        incus profile set default cloud-init.user-data - <<CLOUDINIT
#cloud-config
users:
  - name: vm-admin
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${pubkey}
package_update: true
packages:
  - openssh-server
runcmd:
  - systemctl enable --now sshd 2>/dev/null || systemctl enable --now ssh
  # Su Rocky/RHEL sshd_config non ha "Include /etc/ssh/sshd_config.d/*.conf" di default
  # e ha PasswordAuthentication=no hardcoded: bisogna fixarlo a mano.
  - grep -q "^Include /etc/ssh/sshd_config.d" /etc/ssh/sshd_config || sed -i "1iInclude /etc/ssh/sshd_config.d/*.conf" /etc/ssh/sshd_config
  - sed -i "/^PasswordAuthentication /d" /etc/ssh/sshd_config
  - sed -i "/^PermitRootLogin /d" /etc/ssh/sshd_config
  - systemctl restart sshd 2>/dev/null || systemctl restart ssh
write_files:
  - path: /etc/ssh/sshd_config.d/99-hardening.conf
    content: |
      # PasswordAuthentication abilitato: ma nessun utente ha password di default
      # (vm-admin usa solo chiave). Per consentire login con password, settare
      # esplicitamente una password: incus exec <vm> -- passwd <user>
      PasswordAuthentication yes
      PermitRootLogin no
      MaxAuthTries 3
    permissions: '0644'
    owner: root:root
CLOUDINIT
        log "Cloud-init configurato: utente vm-admin con chiave SSH"
    else
        warn "Chiave SSH non trovata: $SSH_KEY_FILE — cloud-init senza chiave"
    fi

    log "Incus configurato: bridge 10.100.0.0/24, storage in $INCUS_STORAGE"
}

setup_incus_auth() {
    log "Configurazione autenticazione UI..."

    # Genera certificato client per l'utente
    local cert_dir="/home/${INCUS_USER}/.config/incus"
    if [ ! -f "$cert_dir/client.crt" ]; then
        # Il primo comando incus da utente genera automaticamente il cert
        su - "$INCUS_USER" -c "incus list" >/dev/null 2>&1 || true
    fi

    # Crea trust token per la UI
    local token
    token=$(incus config trust add incus-ui --quiet 2>/dev/null || true)
    if [ -n "$token" ]; then
        log "Token UI generato. Salvato per il primo accesso."
        echo "$token" > "/home/${INCUS_USER}/.incus-ui-token"
        chown "${INCUS_USER}:${INCUS_USER}" "/home/${INCUS_USER}/.incus-ui-token"
        chmod 600 "/home/${INCUS_USER}/.incus-ui-token"
    fi
}

setup_nginx_stream() {
    log "Configurazione nginx stream SNI per Incus UI..."

    # Architettura: nginx stream block legge SNI ClientHello senza decriptare.
    # incus.REDACTED_DOMAIN → TCP passthrough a Incus (mTLS intatto per login cert)
    # tutti gli altri   → blocco HTTP interno su porta 8442

    cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%Y%m%d%H%M%S)"

    # 1. Rimuovi eventuale blocco server HTTP per incus (setup precedente)
    if grep -q "server_name ${UI_DOMAIN}" "$NGINX_CONF"; then
        # Rimuovi il blocco server che contiene incus.REDACTED_DOMAIN
        sed -i "/# --- Incus UI/,/^    }/d" "$NGINX_CONF"
        log "Rimosso vecchio blocco HTTP per Incus UI"
    fi

    # 2. Rimuovi incus dal redirect HTTP (porta 80) se presente
    if grep -q "listen 80" "$NGINX_CONF" && grep -q "${UI_DOMAIN}" "$NGINX_CONF"; then
        sed -i "s/ ${UI_DOMAIN}//g" "$NGINX_CONF"
    fi

    # 3. Cambia tutti i 'listen 443' in 'listen 8442' nel blocco http (idempotente)
    sed -i 's/listen 443 ssl http2;/listen 8442 ssl http2;/g; s/listen 443 ssl;/listen 8442 ssl;/g' "$NGINX_CONF"

    # 4. Aggiungi blocco stream (se non presente)
    if ! grep -q "^stream {" "$NGINX_CONF"; then
        # Ricava IP di host.docker.internal dal container nginx
        local host_ip
        host_ip=$(docker exec nginx grep host.docker.internal /etc/hosts 2>/dev/null | awk '{print $1}')
        [ -z "$host_ip" ] && host_ip="172.17.0.1"  # fallback

        cat >> "$NGINX_CONF" <<STREAM

# =============================================================================
# STREAM: SNI-based routing su porta 443
# - incus.REDACTED_DOMAIN → TCP passthrough verso Incus (mTLS intatto)
# - tutti gli altri → blocco HTTP interno su 8442
# =============================================================================
stream {
    map \$ssl_preread_server_name \$upstream_443 {
        ${UI_DOMAIN}  ${host_ip}:8443;
        default            127.0.0.1:8442;
    }

    server {
        listen 443;
        ssl_preread on;
        proxy_pass \$upstream_443;
    }
}
STREAM
        log "Blocco stream SNI aggiunto a nginx.conf"
    else
        log "Blocco stream SNI già presente"
    fi

    # Reload nginx
    docker exec nginx nginx -t 2>/dev/null && docker exec nginx nginx -s reload 2>/dev/null
    log "nginx configurato: stream SNI su 443, HTTP su 8442"
}

setup_le_certs() {
    log "Configurazione certificati Let's Encrypt per Incus..."

    local le_cert="/mnt/nas2/docker/data/certbot/conf/live/REDACTED_HOSTNAME.REDACTED_DDNS/fullchain.pem"
    local le_key="/mnt/nas2/docker/data/certbot/conf/live/REDACTED_HOSTNAME.REDACTED_DDNS/privkey.pem"
    local incus_cert="/var/lib/incus/server.crt"
    local incus_key="/var/lib/incus/server.key"

    if [ ! -f "$le_cert" ]; then
        warn "Certificato LE non trovato: $le_cert — skip"
        return
    fi

    # Verifica se sono già symlink corretti
    if [ -L "$incus_cert" ] && [ "$(readlink -f "$incus_cert")" = "$(readlink -f "$le_cert")" ]; then
        log "Symlink certificato LE già configurato"
        return
    fi

    # Backup self-signed se presente
    [ -f "$incus_cert" ] && [ ! -L "$incus_cert" ] && mv "$incus_cert" "${incus_cert}.selfsigned"
    [ -f "$incus_key" ] && [ ! -L "$incus_key" ] && mv "$incus_key" "${incus_key}.selfsigned"

    ln -sf "$le_cert" "$incus_cert"
    ln -sf "$le_key" "$incus_key"

    systemctl restart incus 2>/dev/null || true
    log "Incus ora usa certificato Let's Encrypt (symlink)"
}

setup_iptables_persistence() {
    log "Configurazione iptables persistence per Docker/Incus coesistenza..."

    cat > /etc/systemd/system/incus-iptables.service <<'IPTUNIT'
[Unit]
Description=iptables rules for Incus bridge (Docker coexistence)
After=network.target docker.service
Before=incus.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/iptables -I FORWARD -i incusbr0 -j ACCEPT
ExecStart=/sbin/iptables -I FORWARD -o incusbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
ExecStop=/sbin/iptables -D FORWARD -i incusbr0 -j ACCEPT
ExecStop=/sbin/iptables -D FORWARD -o incusbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

[Install]
WantedBy=multi-user.target
IPTUNIT

    systemctl daemon-reload
    systemctl enable --now incus-iptables.service
    log "iptables persistence configurato"
}

setup_socat_template() {
    log "Configurazione socat proxy template..."

    mkdir -p "$PROXY_DIR"
    touch "$PORT_MAP" "$PROXY_STATE"
    chmod 644 "$PORT_MAP" "$PROXY_STATE"

    # Systemd template unit per socat port proxy (usato per TUTTI i proxy: SSH + custom)
    cat > /etc/systemd/system/incus-port-proxy@.service <<'PORTUNIT'
[Unit]
Description=Port proxy for Incus VM: %i
After=incus.service incus-iptables.service
Requires=incus.service

[Service]
Type=simple
Restart=on-failure
RestartSec=5
SuccessExitStatus=143
EnvironmentFile=/mnt/nas2/incus-vms/port-proxy/%i.env
ExecStart=/usr/bin/socat TCP-LISTEN:${HOST_PORT},fork,reuseaddr TCP:${VM_IP}:${VM_PORT}

[Install]
WantedBy=multi-user.target
PORTUNIT

    # Assicura socat installato
    command -v socat &>/dev/null || apt-get install -y socat

    systemctl daemon-reload
    log "Template socat proxy creato"
}

setup_vm_ssh_hook() {
    log "Configurazione hook SSH automatico..."

    # Copia l'hook aggiornato (se non esiste già la versione corrente)
    cp "${SCRIPT_DIR}/incus_vm_hook.sh" /mnt/nas2/nas-scripts/incus_vm_hook.sh 2>/dev/null || true
    chmod +x /mnt/nas2/nas-scripts/incus_vm_hook.sh

    # Systemd timer per eseguire l'hook ogni 30 secondi
    cat > /etc/systemd/system/incus-dns-sync.service <<SERVICE
[Unit]
Description=Sync Incus VM SSH proxies
After=incus.service

[Service]
Type=oneshot
ExecStart=/mnt/nas2/nas-scripts/incus_vm_hook.sh
SERVICE

    cat > /etc/systemd/system/incus-dns-sync.timer <<TIMER
[Unit]
Description=Sync Incus VM SSH proxies every 30s

[Timer]
OnBootSec=60
OnUnitActiveSec=30

[Install]
WantedBy=timers.target
TIMER

    systemctl daemon-reload
    systemctl enable --now incus-dns-sync.timer
    log "Hook SSH attivo (sync ogni 30s)"
}

setup_ssh_helper() {
    log "Configurazione helper SSH per VM..."

    cat > /usr/local/bin/vm-ssh <<'VMSSH'
#!/usr/bin/env bash
# Scorciatoia SSH verso VM Incus (via socat port forwarding)
# Uso: vm-ssh nomevm [comandi...]
PORT_MAP="/mnt/nas2/incus-vms/port-map.txt"
VM_NAME="${1:?Uso: vm-ssh <nome-vm> [comandi...]}"
shift
PORT=$(grep "^${VM_NAME}:" "$PORT_MAP" 2>/dev/null | cut -d: -f2)
if [ -z "$PORT" ]; then
    echo "VM '$VM_NAME' non trovata in port-map. VM disponibili:"
    cat "$PORT_MAP" 2>/dev/null | sed 's/^/  /'
    exit 1
fi
echo "→ SSH a ${VM_NAME} (porta ${PORT})..."
exec ssh -o StrictHostKeyChecking=accept-new -p "$PORT" "vm-admin@127.0.0.1" "$@"
VMSSH
    chmod +x /usr/local/bin/vm-ssh
    log "Comando 'vm-ssh <nome>' installato"
}

# --- Export / Restore ---------------------------------------------------------

export_config() {
    log "Esportazione configurazione Incus..."
    mkdir -p "$INCUS_BACKUP_DIR"

    # Dump configurazione incus
    incus admin sql global "SELECT * FROM config" > "$INCUS_BACKUP_DIR/incus-config.sql" 2>/dev/null || true

    # Esporta profili
    incus profile show default > "$INCUS_BACKUP_DIR/profile-default.yaml" 2>/dev/null || true

    # Esporta rete
    incus network show incusbr0 > "$INCUS_BACKUP_DIR/network-incusbr0.yaml" 2>/dev/null || true

    # Esporta storage
    incus storage show default > "$INCUS_BACKUP_DIR/storage-default.yaml" 2>/dev/null || true

    # Lista VM con config
    for vm in $(incus list -f csv -c n 2>/dev/null); do
        incus config show "$vm" --expanded > "$INCUS_BACKUP_DIR/vm-${vm}.yaml"
        log "  Esportata config di $vm"
    done

    # Copia questo script e gli hook
    cp "$0" "$INCUS_BACKUP_DIR/setup_incus.sh"
    cp /mnt/nas2/nas-scripts/incus_vm_hook.sh "$INCUS_BACKUP_DIR/" 2>/dev/null || true

    # Esporta systemd units
    cp /etc/systemd/system/incus-dns-sync.* "$INCUS_BACKUP_DIR/" 2>/dev/null || true
    cp /etc/systemd/system/incus-iptables.service "$INCUS_BACKUP_DIR/" 2>/dev/null || true
    cp /etc/systemd/system/incus-port-proxy@.service "$INCUS_BACKUP_DIR/" 2>/dev/null || true

    # Esporta port-map e env files
    cp "$PORT_MAP" "$INCUS_BACKUP_DIR/" 2>/dev/null || true
    cp "$PROXY_STATE" "$INCUS_BACKUP_DIR/" 2>/dev/null || true
    cp -r "$PROXY_DIR" "$INCUS_BACKUP_DIR/" 2>/dev/null || true

    log "Config esportata in $INCUS_BACKUP_DIR"
    log "Per backup completo delle VM, usa: incus export <vm-name> $INCUS_BACKUP_DIR/<vm>.tar.gz"
}

restore_config() {
    log "Ripristino configurazione Incus..."

    [ -d "$INCUS_BACKUP_DIR" ] || die "Directory backup non trovata: $INCUS_BACKUP_DIR"

    # Reinstalla se necessario
    install_incus
    setup_swap

    # Ripristina da preseed se il profilo è presente
    if [ -f "$INCUS_BACKUP_DIR/profile-default.yaml" ]; then
        configure_incus
    fi

    # Ripristina hook
    if [ -f "$INCUS_BACKUP_DIR/incus_vm_hook.sh" ]; then
        cp "$INCUS_BACKUP_DIR/incus_vm_hook.sh" /mnt/nas2/nas-scripts/
        chmod +x /mnt/nas2/nas-scripts/incus_vm_hook.sh
    fi

    # Ripristina systemd units
    cp "$INCUS_BACKUP_DIR"/incus-dns-sync.* /etc/systemd/system/ 2>/dev/null || true
    cp "$INCUS_BACKUP_DIR"/incus-iptables.service /etc/systemd/system/ 2>/dev/null || true
    cp "$INCUS_BACKUP_DIR"/incus-port-proxy@.service /etc/systemd/system/ 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable --now incus-dns-sync.timer 2>/dev/null || true
    systemctl enable --now incus-iptables.service 2>/dev/null || true

    # Ripristina port-map e env files
    cp "$INCUS_BACKUP_DIR/port-map.txt" "$PORT_MAP" 2>/dev/null || true
    cp "$INCUS_BACKUP_DIR/port-proxy-state.txt" "$PROXY_STATE" 2>/dev/null || true
    mkdir -p "$PROXY_DIR"
    cp -r "$INCUS_BACKUP_DIR/port-proxy/." "$PROXY_DIR/" 2>/dev/null || true

    setup_nginx_stream
    setup_le_certs
    setup_ssh_helper

    # Ripristina VM da export (se presenti)
    for backup in "$INCUS_BACKUP_DIR"/*.tar.gz; do
        [ -f "$backup" ] || continue
        local vm_name
        vm_name=$(basename "$backup" .tar.gz)
        log "Ripristino VM: $vm_name..."
        incus import "$backup" 2>/dev/null || warn "Impossibile ripristinare $vm_name"
    done

    log "Ripristino completato"
}

show_status() {
    echo ""
    echo "=== Incus Status ==="
    systemctl is-active incus >/dev/null 2>&1 && echo -e "Servizio: ${GREEN}attivo${NC}" || echo -e "Servizio: ${RED}inattivo${NC}"
    echo ""

    echo "=== VM ==="
    incus list 2>/dev/null || echo "(nessuna VM)"
    echo ""

    echo "=== Storage ==="
    incus storage info default 2>/dev/null || echo "(non configurato)"
    echo ""

    echo "=== Rete ==="
    incus network info incusbr0 2>/dev/null || echo "(non configurato)"
    echo ""

    echo "=== RAM + Swap ==="
    free -h
    echo ""

    echo "=== SSH Hook ==="
    systemctl is-active incus-dns-sync.timer >/dev/null 2>&1 && echo -e "Timer: ${GREEN}attivo${NC}" || echo -e "Timer: ${RED}inattivo${NC}"
    echo ""

    echo "=== iptables (Docker coesistenza) ==="
    systemctl is-active incus-iptables.service >/dev/null 2>&1 && echo -e "Service: ${GREEN}attivo${NC}" || echo -e "Service: ${RED}inattivo${NC}"
    echo ""

    echo "=== Port Proxy (SSH + Custom) ==="
    if [ -f "$PORT_MAP" ] && [ -s "$PORT_MAP" ]; then
        while IFS=: read -r vm_name vm_port; do
            local svc_state
            svc_state=$(systemctl is-active "incus-port-proxy@${vm_name}--ssh.service" 2>/dev/null || echo "inattivo")
            echo "  ${vm_name} -> SSH porta ${vm_port} (proxy: ${svc_state})"
        done < "$PORT_MAP"
    else
        echo "  (nessuna VM registrata)"
    fi
    if [ -f "$PROXY_STATE" ] && [ -s "$PROXY_STATE" ]; then
        while read -r svc_id; do
            [[ "$svc_id" == *--ssh ]] && continue  # già mostrato sopra
            [ -z "$svc_id" ] && continue
            local svc_state hp vp
            svc_state=$(systemctl is-active "incus-port-proxy@${svc_id}.service" 2>/dev/null || echo "inattivo")
            hp=$(grep "^HOST_PORT=" "$PROXY_DIR/${svc_id}.env" 2>/dev/null | cut -d= -f2)
            vp=$(grep "^VM_PORT=" "$PROXY_DIR/${svc_id}.env" 2>/dev/null | cut -d= -f2)
            echo "  ${svc_id} -> host:${hp} → vm:${vp} (proxy: ${svc_state})"
        done < "$PROXY_STATE"
    fi
    echo ""

    echo "=== UI ==="
    echo "  Incus UI: https://${UI_DOMAIN}"
    echo "  SSH:      vm-ssh <nome-vm>"
    echo ""

    if [ -f "/home/${INCUS_USER}/.incus-ui-token" ]; then
        echo "=== Token UI (primo accesso) ==="
        cat "/home/${INCUS_USER}/.incus-ui-token"
        echo ""
    fi
}

do_uninstall() {
    warn "Rimozione Incus..."
    read -rp "Sei sicuro? Le VM verranno distrutte! (yes/no): " confirm
    [ "$confirm" = "yes" ] || die "Annullato"

    # Stop e rimuovi
    # Ferma tutti i proxy
    for svc in /etc/systemd/system/multi-user.target.wants/incus-port-proxy@*.service; do
        [ -f "$svc" ] && systemctl disable --now "$(basename "$svc")" 2>/dev/null || true
    done

    systemctl disable --now incus-dns-sync.timer 2>/dev/null || true
    systemctl disable --now incus-iptables.service 2>/dev/null || true
    rm -f /etc/systemd/system/incus-dns-sync.*
    rm -f /etc/systemd/system/incus-iptables.service
    rm -f /etc/systemd/system/incus-port-proxy@.service
    rm -f /etc/systemd/system/incus-ssh-proxy@.service
    systemctl daemon-reload

    incus admin shutdown 2>/dev/null || true
    apt-get remove -y incus incus-ui-canonical 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/zabbly-incus-stable.sources
    rm -f /etc/apt/keyrings/zabbly.gpg
    rm -f /usr/local/bin/vm-ssh

    # Ripristina cert self-signed se presenti i backup
    [ -f /var/lib/incus/server.crt.selfsigned ] && mv /var/lib/incus/server.crt.selfsigned /var/lib/incus/server.crt
    [ -f /var/lib/incus/server.key.selfsigned ] && mv /var/lib/incus/server.key.selfsigned /var/lib/incus/server.key
    rm -f /var/lib/incus/server.crt /var/lib/incus/server.key 2>/dev/null

    log "Incus rimosso. Storage in $INCUS_STORAGE NON cancellato (rimuovilo manualmente se vuoi)."
}

# --- Main ---------------------------------------------------------------------

case "${1:-}" in
    install)
        [ "$(id -u)" -eq 0 ] || die "Esegui come root: sudo $0 install"
        install_incus
        setup_swap
        configure_incus
        setup_incus_auth
        setup_iptables_persistence
        setup_socat_template
        setup_nginx_stream
        setup_le_certs
        setup_vm_ssh_hook
        setup_ssh_helper
        echo ""
        log "=========================================="
        log "  Installazione completata!"
        log "=========================================="
        log ""
        log "  UI:    https://${UI_DOMAIN}"
        log "  SSH:   vm-ssh <nome-vm>"
        log ""
        log "  Crea la tua prima VM:"
        log "    incus launch images:ubuntu/24.04/cloud myvm --vm"
        log ""
        log "  La VM riceverà automaticamente:"
        log "    - SSH server + chiave host (via cloud-init)"
        log "    - Porta SSH dedicata (2201-2299 via socat)"
        log "    - Accesso: vm-ssh myvm"
        log ""
        if [ -f "/home/${INCUS_USER}/.incus-ui-token" ]; then
            log "  Token per primo accesso UI:"
            log "  $(cat /home/${INCUS_USER}/.incus-ui-token)"
        fi
        log ""
        log "  NOTA: rilogga la sessione per attivare il gruppo incus-admin"
        log "    newgrp incus-admin"
        log "=========================================="
        ;;
    uninstall)
        [ "$(id -u)" -eq 0 ] || die "Esegui come root: sudo $0 uninstall"
        do_uninstall
        ;;
    status)
        show_status
        ;;
    export)
        [ "$(id -u)" -eq 0 ] || die "Esegui come root: sudo $0 export"
        export_config
        ;;
    restore)
        [ "$(id -u)" -eq 0 ] || die "Esegui come root: sudo $0 restore"
        restore_config
        ;;
    *)
        echo "Uso: $0 {install|uninstall|status|export|restore}"
        echo ""
        echo "  install   — Installa Incus + UI + swap + nginx + hook DNS"
        echo "  uninstall — Rimuove Incus (chiede conferma)"
        echo "  status    — Mostra stato del sistema"
        echo "  export    — Esporta config per migrazione"
        echo "  restore   — Ripristina su nuovo server"
        exit 1
        ;;
esac
