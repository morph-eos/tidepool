#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# SETUP INCUS — VM Manager con UI Web + SSH proxy automatico
# =============================================================================
# Installa e configura Incus + UI Canonical per gestione VM via browser.
# Pensato per Ubuntu 24.04, compatibile con Docker coesistente.
#
# Funzionalità:
#   - Incus con storage LVM thin loop-backed (quote rigide, zero repartition)
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
#   sudo bash /mnt/nas2/nas-scripts/setup_incus.sh trust-certs
#   sudo bash /mnt/nas2/nas-scripts/setup_incus.sh migrate-storage
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INCUS_STORAGE="/mnt/nas2/incus-vms"
INCUS_POOL="vmquota"
INCUS_POOL_DRIVER="lvm"
INCUS_POOL_SIZE="200GiB"
INCUS_LEGACY_POOLS=("default" "vmpool")
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
INCUS_TRUST_DIR="${SCRIPT_DIR}/incus-trust"

# Colori
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INCUS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

active_storage_pool() {
    local pool
    pool=$(incus profile device get default root pool 2>/dev/null || true)
    if [ -n "$pool" ]; then
        echo "$pool"
        return 0
    fi
    if incus storage show "$INCUS_POOL" &>/dev/null; then
        echo "$INCUS_POOL"
        return 0
    fi
    if incus storage show default &>/dev/null; then
        echo "default"
        return 0
    fi
    incus storage list --format csv -c n 2>/dev/null | head -1
}

pool_driver() {
    incus storage show "$1" 2>/dev/null | awk '/^driver:/ {print $2; exit}'
}

setup_quota_storage_deps() {
    if [ "$INCUS_POOL_DRIVER" = "lvm" ]; then
        if ! command -v lvm &>/dev/null || ! command -v thin_check &>/dev/null; then
            log "Installazione dipendenze storage LVM thin..."
            apt-get update -qq
            apt-get install -y lvm2 thin-provisioning-tools
        fi
    fi
}

ensure_quota_pool() {
    setup_quota_storage_deps

    if incus storage show "$INCUS_POOL" &>/dev/null; then
        local driver
        driver=$(pool_driver "$INCUS_POOL")
        [ "$driver" = "$INCUS_POOL_DRIVER" ] || die "Pool ${INCUS_POOL} esiste ma driver=${driver}, atteso ${INCUS_POOL_DRIVER}"
        log "Pool '${INCUS_POOL}' già esistente (${INCUS_POOL_DRIVER}) — skip creazione"
        return 0
    fi

    log "Creazione pool '${INCUS_POOL}' (${INCUS_POOL_DRIVER}, ${INCUS_POOL_SIZE}, loop file gestito da Incus)..."
    incus storage create "$INCUS_POOL" "$INCUS_POOL_DRIVER" size="$INCUS_POOL_SIZE"
    log "Pool '${INCUS_POOL}' creato: quote rigide via LVM thin"
}

stop_running_instances() {
    local -n out_ref=$1
    out_ref=()
    local vm vm_state
    for vm in $(incus list -f csv -c n 2>/dev/null); do
        vm_state=$(incus list -f csv -c s "$vm" 2>/dev/null | tr -d ' ')
        if [ "$vm_state" = "RUNNING" ]; then
            out_ref+=("$vm")
            log "  ${vm}: stop..."
            incus stop "$vm" --force 2>/dev/null || true
        fi
    done

    for vm in "${out_ref[@]}"; do
        local wait=0
        while incus list -f csv -c s "$vm" 2>/dev/null | grep -qi running; do
            sleep 2; wait=$((wait+2))
            [ $wait -ge 60 ] && die "Timeout stop $vm"
        done
    done
}

restart_instances() {
    local vm
    for vm in "$@"; do
        log "  ${vm}: start..."
        incus start "$vm"
    done
}

instance_root_pool() {
    incus config show "$1" --expanded 2>/dev/null | awk '
        /^  root:/ {in_root=1; next}
        in_root && /^  [^ ]/ {in_root=0}
        in_root && /pool:/ {print $2; exit}
    '
}

update_custom_disk_device_pools() {
    local target_pool="$1" vm dev type source current_pool
    for vm in $(incus list -f csv -c n 2>/dev/null); do
        for dev in $(incus config device list "$vm" 2>/dev/null); do
            type=$(incus config device get "$vm" "$dev" type 2>/dev/null || true)
            [ "$type" = "disk" ] || continue
            source=$(incus config device get "$vm" "$dev" source 2>/dev/null || true)
            [ -n "$source" ] || continue
            incus storage volume show "$target_pool" "custom/${source}" &>/dev/null || continue
            current_pool=$(incus config device get "$vm" "$dev" pool 2>/dev/null || true)
            if [ "$current_pool" != "$target_pool" ]; then
                log "  ${vm}/${dev}: pool ${current_pool:-unset} → ${target_pool}"
                incus config device set "$vm" "$dev" pool "$target_pool"
            fi
        done
    done
}

cleanup_empty_legacy_pools() {
    local pool used_by
    log "Rimozione pool legacy vuoti..."
    for pool in "${INCUS_LEGACY_POOLS[@]}"; do
        [ "$pool" != "$INCUS_POOL" ] || continue
        incus storage show "$pool" &>/dev/null || continue
        used_by=$(incus storage show "$pool" 2>/dev/null | awk '
            /^used_by: \[\]/ {print 0; found=1; exit}
            /^used_by:/ {in_used=1; next}
            in_used && /^  - / {count++; next}
            in_used && /^[^ ]/ {print count+0; found=1; exit}
            END {if (in_used && !found) print count+0}
        ')
        [ -n "$used_by" ] || used_by=1
        if [ "$used_by" -eq 0 ]; then
            log "  Elimino pool legacy vuoto '${pool}'..."
            incus storage delete "$pool"
        else
            warn "  Pool legacy '${pool}' ancora in uso da ${used_by} risorse — lasciato intatto"
        fi
    done
}

quota_pool_migration_needed() {
    local vm pool profile_pool
    profile_pool=$(incus profile device get default root pool 2>/dev/null || true)
    [ "$profile_pool" = "$INCUS_POOL" ] || return 0

    for vm in $(incus list -f csv -c n 2>/dev/null); do
        pool=$(instance_root_pool "$vm")
        [ "$pool" = "$INCUS_POOL" ] || return 0
    done

    for pool in $(incus storage list --format csv -c n 2>/dev/null); do
        [ "$pool" = "$INCUS_POOL" ] && continue
        if incus storage volume list "$pool" --format csv -c t 2>/dev/null | grep -qx 'custom'; then
            return 0
        fi
    done

    return 1
}

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
    setup_quota_storage_deps

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
    - name: ${INCUS_POOL}
      driver: ${INCUS_POOL_DRIVER}
      config:
        size: ${INCUS_POOL_SIZE}
profiles:
  - name: default
    config:
      limits.cpu: "2"
      limits.memory: 2GB
    devices:
      root:
        path: /
        pool: ${INCUS_POOL}
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
  # Prefisso 01- per vincere su 50-cloud-init.conf (Rocky/RHEL forza
  # PasswordAuthentication=no nel file di cloud-init): sshd_config.d e' caricato
  # in ordine alfabetico e per ogni direttiva vince la PRIMA occorrenza.
  - path: /etc/ssh/sshd_config.d/01-REDACTED_BRAND_lc-defaults.conf
    content: |
      # Policy REDACTED_BRAND: SSH password auth ABILITATA, ma per default NESSUN utente
      # ha una password (vm-admin e altri utenti cloud-init sono creati con
      # password locked). L'amministratore della VM puo' creare utenti con
      # password ad-hoc:
      #   incus exec <vm> -- useradd -m <user> && incus exec <vm> -- passwd <user>
      # Oppure assegnare una password a un utente esistente:
      #   incus exec <vm> -- passwd <user>
      PasswordAuthentication yes
      KbdInteractiveAuthentication yes
      PermitRootLogin no
      MaxAuthTries 3
    permissions: '0644'
    owner: root:root
CLOUDINIT
        log "Cloud-init configurato: utente vm-admin con chiave SSH"
    else
        warn "Chiave SSH non trovata: $SSH_KEY_FILE — cloud-init senza chiave"
    fi

    log "Incus configurato: bridge 10.100.0.0/24, storage ${INCUS_POOL} (${INCUS_POOL_DRIVER}, ${INCUS_POOL_SIZE})"
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

setup_trusted_client_certs() {
    log "Configurazione certificati client Incus trusted..."

    [ -d "$INCUS_TRUST_DIR" ] || { log "Nessuna directory trust presente: $INCUS_TRUST_DIR"; return; }

    local cert_file cert_name fingerprint existing_name
    for cert_file in "$INCUS_TRUST_DIR"/*.crt; do
        [ -f "$cert_file" ] || continue
        cert_name=$(basename "$cert_file" .crt)
        fingerprint=$(openssl x509 -in "$cert_file" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')
        existing_name=$(incus config trust show "$fingerprint" 2>/dev/null | awk '/^name:/ {print $2; exit}')

        if [ -n "$existing_name" ]; then
            if [ "$existing_name" != "$cert_name" ]; then
                incus config trust edit "$fingerprint" <<TRUST
name: ${cert_name}
description: Managed by setup_incus.sh from ${cert_file}
restricted: false
projects: []
TRUST
                log "Certificato client rinominato: ${existing_name} -> ${cert_name}"
            else
                log "Certificato client già trusted: ${cert_name}"
            fi
            continue
        fi

        incus config trust add-certificate "$cert_file" --name "$cert_name"
        log "Certificato client aggiunto: ${cert_name}"
    done
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
    sed -i 's/listen 443 ssl http2;/listen 8442 ssl http2;/g; s/listen 443 ssl;/listen 8442 ssl;/g; s/listen \[::\]:443 ssl http2;/listen [::]:8442 ssl http2;/g; s/listen \[::\]:443 ssl;/listen [::]:8442 ssl;/g' "$NGINX_CONF"

    # 3b. Assicura HTTP/80 per ACME challenge e redirect generico.
    if ! grep -q "HTTP ACME CHALLENGE" "$NGINX_CONF"; then
        sed -i '/set_real_ip_from 10\.0\.0\.0\/8;/a\
\
    # ========================================================================\
    # HTTP ACME CHALLENGE + REDIRECT\
    # ========================================================================\
    server {\
        listen 80 default_server;\
        listen [::]:80 default_server;\
        server_name _;\
\
        location ^~ /.well-known/acme-challenge/ {\
            root /var/www/certbot;\
        }\
\
        location / {\
            return 301 https://$host$request_uri;\
        }\
    }' "$NGINX_CONF"
        log "Blocco HTTP/80 per ACME aggiunto"
    else
        log "Blocco HTTP/80 per ACME già presente"
    fi

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

    if ! openssl x509 -in "$le_cert" -noout -ext subjectAltName | grep -q "DNS:${UI_DOMAIN}"; then
        warn "Il certificato unico non contiene ${UI_DOMAIN}. Rigenera certbot includendo -d ${UI_DOMAIN}."
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
    log "Incus ora usa il certificato Let's Encrypt unico (symlink)"
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
    local storage_pool
    storage_pool=$(active_storage_pool)

    # Dump configurazione incus
    incus admin sql global "SELECT * FROM config" > "$INCUS_BACKUP_DIR/incus-config.sql" 2>/dev/null || true

    # Esporta profili
    incus profile show default > "$INCUS_BACKUP_DIR/profile-default.yaml" 2>/dev/null || true

    # Esporta rete
    incus network show incusbr0 > "$INCUS_BACKUP_DIR/network-incusbr0.yaml" 2>/dev/null || true

    # Esporta storage
    if [ -n "$storage_pool" ]; then
        incus storage show "$storage_pool" > "$INCUS_BACKUP_DIR/storage-${storage_pool}.yaml" 2>/dev/null || true
    fi

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
    setup_trusted_client_certs
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
    local storage_pool
    storage_pool=$(active_storage_pool)

    echo ""
    echo "=== Incus Status ==="
    systemctl is-active incus >/dev/null 2>&1 && echo -e "Servizio: ${GREEN}attivo${NC}" || echo -e "Servizio: ${RED}inattivo${NC}"
    echo ""

    echo "=== VM ==="
    incus list 2>/dev/null || echo "(nessuna VM)"
    echo ""

    echo "=== Storage ==="
    if [ -n "$storage_pool" ]; then
        incus storage info "$storage_pool" 2>/dev/null || echo "(non configurato)"
    else
        echo "(non configurato)"
    fi
    echo ""

    echo "=== Storage Quotas ==="
    local storage_driver storage_source storage_fs storage_opts
    storage_driver=$(incus storage show "$storage_pool" 2>/dev/null | awk '/^driver:/ {print $2; exit}')
    storage_source=$(incus storage show "$storage_pool" 2>/dev/null | awk '/^  source:/ {print $2; exit}')
    storage_fs=$(findmnt -T "$storage_source" -no FSTYPE 2>/dev/null || true)
    storage_opts=$(findmnt -T "$storage_source" -no OPTIONS 2>/dev/null || true)
    if [ "$storage_driver" = "dir" ]; then
        echo "Driver: dir su ${storage_source:-unknown} (${storage_fs:-unknown})"
        if [[ "$storage_opts" == *prjquota* || "$storage_opts" == *pquota* ]]; then
            echo -e "Quote custom filesystem: ${GREEN}project quota rilevate${NC}"
        else
            echo -e "Quote custom filesystem: ${YELLOW}non garantite${NC} (manca prjquota/pquota sul mount)"
        fi
    elif [ "$storage_driver" = "lvm" ]; then
        echo "Driver: lvm thin su pool ${storage_pool:-unknown}"
        echo -e "Quote block/filesystem: ${GREEN}garantite dal thin volume size${NC}"
    elif [ "$storage_driver" = "btrfs" ]; then
        echo "Driver: btrfs su pool ${storage_pool:-unknown}"
        echo -e "Quote block/filesystem: ${YELLOW}non considerate al 100% dalla UI Incus${NC}"
    else
        echo "Driver: ${storage_driver:-unknown}"
    fi
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
            if systemctl is-active --quiet "incus-port-proxy@${vm_name}--ssh.service" 2>/dev/null; then
                svc_state="attivo"
            else
                svc_state="inattivo"
            fi
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
            if systemctl is-active --quiet "incus-port-proxy@${svc_id}.service" 2>/dev/null; then
                svc_state="attivo"
            else
                svc_state="inattivo"
            fi
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

# --- Migrazione storage: pool con quote rigide (LVM thin, idempotente) --------

migrate_to_quota_pool() {
    log "=== Migrazione storage a pool con quote rigide (${INCUS_POOL_DRIVER}: ${INCUS_POOL}) ==="
    log "Il pool e' loop-backed e gestito da Incus: nessun disco NAS viene ripartizionato o formattato."

    ensure_quota_pool

    if ! quota_pool_migration_needed; then
        log "Tutte le istanze, i volumi custom e il profilo default usano già '${INCUS_POOL}' — no-op"
        update_custom_disk_device_pools "$INCUS_POOL"
        cleanup_empty_legacy_pools
        return 0
    fi

    local running_vms=()
    log "Stop istanze per migrazione storage..."
    stop_running_instances running_vms

    log "Migrazione istanze verso ${INCUS_POOL}..."
    local vm vm_pool
    for vm in $(incus list -f csv -c n 2>/dev/null); do
        vm_pool=$(instance_root_pool "$vm")
        if [ "$vm_pool" = "$INCUS_POOL" ]; then
            log "  ${vm}: già su ${INCUS_POOL} — skip"
            continue
        fi
        log "  ${vm}: ${vm_pool:-unknown} → ${INCUS_POOL}..."
        incus move "$vm" "$vm" --storage "$INCUS_POOL"
        log "  ${vm}: migrata ✓"
    done

    log "Migrazione volumi custom verso ${INCUS_POOL}..."
    local pool vol target_exists
    for pool in $(incus storage list --format csv -c n 2>/dev/null); do
        [ "$pool" != "$INCUS_POOL" ] || continue
        for vol in $(incus storage volume list "$pool" --format csv -c t,n 2>/dev/null | awk -F, '$1=="custom" {print $2}'); do
            target_exists=false
            incus storage volume show "$INCUS_POOL" "custom/${vol}" &>/dev/null && target_exists=true
            if $target_exists; then
                warn "  Volume '${vol}' esiste già su ${INCUS_POOL}; non sovrascrivo"
                continue
            fi
            log "  ${pool}/${vol} → ${INCUS_POOL}/${vol}..."
            incus storage volume move "${pool}/${vol}" "${INCUS_POOL}/${vol}"
            log "  ${vol}: migrato ✓"
        done
    done

    log "Aggiornamento device custom disk sulle VM..."
    update_custom_disk_device_pools "$INCUS_POOL"

    log "Aggiornamento profilo default..."
    incus profile device set default root pool "$INCUS_POOL"
    incus profile device set default root size 20GB
    log "Profilo default → pool '${INCUS_POOL}', root.size=20GB"

    cleanup_empty_legacy_pools

    log "Riavvio istanze precedentemente attive..."
    restart_instances "${running_vms[@]}"

    log "=== Migrazione completata ==="
    log "Pool attivo: ${INCUS_POOL} (${INCUS_POOL_DRIVER}, quote rigide per block e filesystem volume)"
    log "Loop file gestito da Incus sotto /var/lib/incus/disks/; nessun dato NAS toccato."
    log "Per ridimensionare il pool: incus storage set ${INCUS_POOL} size=<new_size>"
}

migrate_to_btrfs() {
    warn "migrate_to_btrfs e' deprecato: uso il pool LVM con quote rigide."
    migrate_to_quota_pool
}

# --- Migrazione volumi custom: filesystem → block (idempotente) ---------------
# I volumi block espongono la dimensione corretta a df nella VM (no quirk virtiofs).

migrate_volumes_to_block() {
    log "=== Migrazione volumi custom a content-type=block ==="

    local pool="$INCUS_POOL"

    # Elenca volumi custom di tipo filesystem
    local vols
    vols=$(incus storage volume list "$pool" --format csv -c t,n,d 2>/dev/null | awk -F, '$1=="custom" {print $2}')

    if [ -z "$vols" ]; then
        log "Nessun volume custom trovato su pool '${pool}'"
        return 0
    fi

    for vol in $vols; do
        local content_type
        content_type=$(incus storage volume show "$pool" "custom/${vol}" 2>/dev/null | grep "^content_type:" | awk '{print $2}')

        if [ "$content_type" = "block" ]; then
            log "  ${vol}: già block — skip"
            continue
        fi

        log "  ${vol}: conversione filesystem → block..."

        # Trova la VM che usa questo volume e il path
        local attached_vm="" device_name=""
        for vm in $(incus list -f csv -c n 2>/dev/null); do
            local dev
            dev=$(incus config device show "$vm" 2>/dev/null | grep -B5 "source: ${vol}$" | head -1 | tr -d ':' | tr -d ' ' || true)
            if [ -n "$dev" ]; then
                attached_vm="$vm"
                device_name="$dev"
                break
            fi
        done

        # Recupera dimensione attuale
        local vol_size
        vol_size=$(incus storage volume get "$pool" "custom/${vol}" size 2>/dev/null || echo "")
        [ -z "$vol_size" ] && vol_size="20GiB"

        # Stop VM se necessario
        local was_running=false
        if [ -n "$attached_vm" ]; then
            local vm_state
            vm_state=$(incus list -f csv -c s "$attached_vm" 2>/dev/null | tr -d ' ')
            if [ "$vm_state" = "RUNNING" ]; then
                was_running=true
                log "    Stop ${attached_vm}..."
                incus stop "$attached_vm" --force
                local wait=0
                while incus list -f csv -c s "$attached_vm" 2>/dev/null | grep -qi running; do
                    sleep 2; wait=$((wait+2))
                    [ $wait -ge 60 ] && die "Timeout stop $attached_vm"
                done
            fi
            # Rimuovi device dalla VM
            log "    Rimuovo device '${device_name}' da ${attached_vm}..."
            incus config device remove "$attached_vm" "$device_name"
        fi

        # Elimina vecchio volume filesystem
        log "    Elimino volume filesystem '${vol}'..."
        incus storage volume delete "$pool" "custom/${vol}"

        # Crea nuovo volume block con stessa dimensione
        log "    Creo volume block '${vol}' (${vol_size})..."
        incus storage volume create "$pool" "${vol}" --type block size="${vol_size}"

        # Ri-collega alla VM
        if [ -n "$attached_vm" ]; then
            log "    Collego a ${attached_vm} come /dev/sdX..."
            incus config device add "$attached_vm" "$device_name" disk pool="$pool" source="${vol}"
        fi

        # Riavvia VM
        if $was_running; then
            log "    Riavvio ${attached_vm}..."
            incus start "$attached_vm"
        fi

        log "  ${vol}: convertito a block ✓"
    done

    log "=== Migrazione volumi block completata ==="
    log ""
    log "NOTA: I volumi block vanno formattati dentro la VM:"
    log "  lsblk                          # identifica il disco (es. /dev/sdb)"
    log "  sudo mkfs.ext4 /dev/sdb"
    log "  sudo mount /dev/sdb /mnt/REDACTED_MOUNT"
    log "  echo '/dev/sdb /mnt/REDACTED_MOUNT ext4 defaults 0 2' | sudo tee -a /etc/fstab"
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

# Applica la policy SSH REDACTED_BRAND a tutte le VM RUNNING (idempotente).
# Policy: PasswordAuthentication=yes, PermitRootLogin=no, MaxAuthTries=3.
# Vince su /etc/ssh/sshd_config.d/50-cloud-init.conf grazie al prefisso 01-.
# Non assegna password ad alcun utente: l'admin sceglie a chi crearne una.
fix_vm_ssh_policy() {
    local vm changed total=0 ok=0
    log "Applico policy SSH REDACTED_BRAND a tutte le VM RUNNING..."
    for vm in $(incus list --format csv -c n,s 2>/dev/null | awk -F, '$2=="RUNNING"{print $1}'); do
        total=$((total+1))
        # Push del file di policy + cleanup legacy + reload sshd, tutto idempotente.
        if incus exec "$vm" -- bash -s <<'BASH'; then
set -e
mkdir -p /etc/ssh/sshd_config.d
desired_path=/etc/ssh/sshd_config.d/01-REDACTED_BRAND_lc-defaults.conf
desired_content='# Policy REDACTED_BRAND: SSH password auth ABILITATA, ma per default NESSUN utente
# ha una password (vm-admin e altri utenti cloud-init sono creati con
# password locked). L'"'"'amministratore della VM puo'"'"' creare utenti con
# password ad-hoc:
#   incus exec <vm> -- useradd -m <user> && incus exec <vm> -- passwd <user>
# Oppure assegnare una password a un utente esistente:
#   incus exec <vm> -- passwd <user>
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitRootLogin no
MaxAuthTries 3'
changed=0
if ! [ -f "$desired_path" ] || ! diff -q <(printf '%s\n' "$desired_content") "$desired_path" >/dev/null 2>&1; then
    printf '%s\n' "$desired_content" > "$desired_path"
    chmod 0644 "$desired_path"
    changed=1
fi
# Assicurati che sshd_config includa la dir (Rocky/RHEL non lo fa di default)
if ! grep -q "^Include /etc/ssh/sshd_config.d" /etc/ssh/sshd_config; then
    sed -i "1iInclude /etc/ssh/sshd_config.d/*.conf" /etc/ssh/sshd_config
    changed=1
fi
# Pulisci direttive duplicate nel main config che potrebbero mascherare gli include
sed -i "/^PasswordAuthentication /d;/^PermitRootLogin /d" /etc/ssh/sshd_config && true
if [ "$changed" -eq 1 ]; then
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || \
        systemctl restart sshd 2>/dev/null || systemctl restart ssh
fi
# Verifica effettiva
sshd -T 2>/dev/null | grep -E "^(passwordauthentication|permitrootlogin)" | head -2
BASH
            ok=$((ok+1))
            log "  $vm: OK"
        else
            warn "  $vm: errore applicando la policy (skip)"
        fi
    done
    log "Policy SSH applicata: $ok/$total VM"
}

case "${1:-}" in
    install)
        [ "$(id -u)" -eq 0 ] || die "Esegui come root: sudo $0 install"
        install_incus
        setup_swap
        configure_incus
        setup_incus_auth
        setup_trusted_client_certs
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
    trust-certs)
        [ "$(id -u)" -eq 0 ] || die "Esegui come root: sudo $0 trust-certs"
        setup_trusted_client_certs
        ;;
    migrate-storage)
        [ "$(id -u)" -eq 0 ] || die "Esegui come root: sudo $0 migrate-storage"
        migrate_to_quota_pool
        ;;
    migrate-quota-storage)
        [ "$(id -u)" -eq 0 ] || die "Esegui come root: sudo $0 migrate-quota-storage"
        migrate_to_quota_pool
        ;;
    migrate-volumes-block)
        [ "$(id -u)" -eq 0 ] || die "Esegui come root: sudo $0 migrate-volumes-block"
        migrate_volumes_to_block
        ;;
    fix-vm-ssh)
        [ "$(id -u)" -eq 0 ] || die "Esegui come root: sudo $0 fix-vm-ssh"
        fix_vm_ssh_policy
        ;;
    *)
        echo "Uso: $0 {install|uninstall|status|export|restore|trust-certs|migrate-storage|migrate-quota-storage|migrate-volumes-block|fix-vm-ssh}"
        echo ""
        echo "  install               — Installa Incus + UI + swap + nginx + hook DNS"
        echo "  uninstall             — Rimuove Incus (chiede conferma)"
        echo "  status                — Mostra stato del sistema"
        echo "  export                — Esporta config per migrazione"
        echo "  restore               — Ripristina su nuovo server"
        echo "  trust-certs           — Importa i certificati client in incus-trust/"
        echo "  migrate-storage       — Migra a pool LVM thin con quote rigide"
        echo "  migrate-quota-storage — Alias esplicito di migrate-storage"
        echo "  migrate-volumes-block — Converte volumi custom da filesystem a block"
        echo "  fix-vm-ssh            — Applica policy SSH REDACTED_BRAND a tutte le VM RUNNING"
        exit 1
        ;;
esac
