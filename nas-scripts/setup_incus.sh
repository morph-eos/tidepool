#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# SETUP INCUS — VM Manager with Web UI + automatic SSH proxy
# =============================================================================
# Installs and configures Incus + Canonical UI to manage VMs from the browser.
# Designed for Ubuntu 24.04, compatible with a coexisting Docker.
#
# Features:
#   - Incus with LVM thin loop-backed storage (hard quotas, zero repartitioning)
#   - Web UI on incus.REDACTED_DOMAIN (via nginx reverse proxy)
#   - Automatic SSH proxy: ports 2201-2299 per VM via socat + systemd
#   - Cloud-init: SSH + host key automatically injected into the VMs
#   - iptables persistence for Docker/Incus coexistence
#   - Swap enlarged to 16 GB on SSD to support more VMs
#   - zram for RAM compression
#
# Usage:
#   sudo bash /mnt/nas2/nas-scripts/setup_incus.sh install
#   sudo bash /mnt/nas2/nas-scripts/setup_incus.sh uninstall
#   sudo bash /mnt/nas2/nas-scripts/setup_incus.sh status
#   sudo bash /mnt/nas2/nas-scripts/setup_incus.sh export   # export config for restore
#   sudo bash /mnt/nas2/nas-scripts/setup_incus.sh restore  # restore on a new server
#   sudo bash /mnt/nas2/nas-scripts/setup_incus.sh trust-certs
#   sudo bash /mnt/nas2/nas-scripts/setup_incus.sh migrate-storage
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INCUS_STORAGE="/mnt/nas2/incus-vms"
INCUS_POOL="vmquota"
INCUS_POOL_DRIVER="lvm"
INCUS_POOL_SIZE="200GiB"
INCUS_LEGACY_POOLS=("default" "vmpool")
# Backing file of the loop-backed LVM thin pool. By default Incus creates it in
# /var/lib/incus/disks/ (SYSTEM disk, /). Since the thin pool advertises
# 200GiB but physically lives on the file, growth beyond the real space of /
# fills the system disk -> I/O error/dqlite corruption. We relocate it to the
# data disk (/mnt/nas) keeping a symlink at the original path: the Incus config
# (source:) stays unchanged, no change to the DB. See relocate-pool.
INCUS_POOL_IMG_DEFAULT="/var/lib/incus/disks/vmquota.img"
INCUS_POOL_IMG_DIR="/mnt/nas/incus"
INCUS_POOL_IMG="${INCUS_POOL_IMG_DIR}/vmquota.img"
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

# Colors
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

# --- Installation functions --------------------------------------------------

install_incus() {
    log "Installazione Incus..."

    # Official Incus repo (zabbly)
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

    # Add the user to the incus-admin group
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
        # Ensure fstab
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

    # Lower swappiness — prefer RAM, use swap only under pressure
    sysctl -w vm.swappiness=30 >/dev/null
    grep -q "vm.swappiness" /etc/sysctl.d/99-vm.conf 2>/dev/null || \
        echo "vm.swappiness=30" > /etc/sysctl.d/99-vm.conf
}

configure_incus() {
    log "Configurazione Incus..."

    # Storage directory
    mkdir -p "$INCUS_STORAGE"
    setup_quota_storage_deps

    # Preseed config (non-interactive)
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

    # Cloud-init: create a uniform vm-admin user (works on Ubuntu, Rocky, Debian, etc.)
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
  # On Rocky/RHEL sshd_config does not have "Include /etc/ssh/sshd_config.d/*.conf" by default
  # and has PasswordAuthentication=no hardcoded: it must be fixed by hand.
  - grep -q "^Include /etc/ssh/sshd_config.d" /etc/ssh/sshd_config || sed -i "1iInclude /etc/ssh/sshd_config.d/*.conf" /etc/ssh/sshd_config
  - sed -i "/^PasswordAuthentication /d" /etc/ssh/sshd_config
  - sed -i "/^PermitRootLogin /d" /etc/ssh/sshd_config
  - systemctl restart sshd 2>/dev/null || systemctl restart ssh
write_files:
  # 01- prefix to win over 50-cloud-init.conf (Rocky/RHEL forces
  # PasswordAuthentication=no in the cloud-init file): sshd_config.d is loaded
  # in alphabetical order and the FIRST occurrence of each directive wins.
  - path: /etc/ssh/sshd_config.d/01-REDACTED_BRAND_lc-defaults.conf
    content: |
      # REDACTED_BRAND policy: SSH password auth ENABLED, but by default NO user
      # has a password (vm-admin and other cloud-init users are created with
      # a locked password). The VM administrator can create users with
      # ad-hoc passwords:
      #   incus exec <vm> -- useradd -m <user> && incus exec <vm> -- passwd <user>
      # Or assign a password to an existing user:
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

    # Generate a client certificate for the user
    local cert_dir="/home/${INCUS_USER}/.config/incus"
    if [ ! -f "$cert_dir/client.crt" ]; then
        # The first incus command by the user automatically generates the cert
        su - "$INCUS_USER" -c "incus list" >/dev/null 2>&1 || true
    fi

    # Create a trust token for the UI
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

    # Architecture: the nginx stream block reads the SNI ClientHello without decrypting.
    # incus.REDACTED_DOMAIN → TCP passthrough to Incus (mTLS intact for cert login)
    # all the others   → internal HTTP block on port 8442

    cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%Y%m%d%H%M%S)"

    # 1. Remove any HTTP server block for incus (previous setup)
    if grep -q "server_name ${UI_DOMAIN}" "$NGINX_CONF"; then
        # Remove the server block that contains incus.REDACTED_DOMAIN
        sed -i "/# --- Incus UI/,/^    }/d" "$NGINX_CONF"
        log "Rimosso vecchio blocco HTTP per Incus UI"
    fi

    # 2. Remove incus from the HTTP redirect (port 80) if present
    if grep -q "listen 80" "$NGINX_CONF" && grep -q "${UI_DOMAIN}" "$NGINX_CONF"; then
        sed -i "s/ ${UI_DOMAIN}//g" "$NGINX_CONF"
    fi

    # 3. Change every 'listen 443' to 'listen 8442' in the http block (idempotent)
    sed -i 's/listen 443 ssl http2;/listen 8442 ssl http2;/g; s/listen 443 ssl;/listen 8442 ssl;/g; s/listen \[::\]:443 ssl http2;/listen [::]:8442 ssl http2;/g; s/listen \[::\]:443 ssl;/listen [::]:8442 ssl;/g' "$NGINX_CONF"

    # 3b. Ensure HTTP/80 for the ACME challenge and the generic redirect.
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

    # 4. Add the stream block (if not present)
    if ! grep -q "^stream {" "$NGINX_CONF"; then
        # Get the IP of host.docker.internal from the nginx container
        local host_ip
        host_ip=$(docker exec nginx grep host.docker.internal /etc/hosts 2>/dev/null | awk '{print $1}')
        [ -z "$host_ip" ] && host_ip="172.17.0.1"  # fallback

        cat >> "$NGINX_CONF" <<STREAM

# =============================================================================
# STREAM: SNI-based routing on port 443
# - incus.REDACTED_DOMAIN → TCP passthrough to Incus (mTLS intact)
# - all the others → internal HTTP block on 8442
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

    # Check whether they are already correct symlinks
    if [ -L "$incus_cert" ] && [ "$(readlink -f "$incus_cert")" = "$(readlink -f "$le_cert")" ]; then
        log "Symlink certificato LE già configurato"
        return
    fi

    # Self-signed backup if present
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

    # Systemd template unit for the socat port proxy (used for ALL proxies: SSH + custom)
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

    # Ensure socat is installed
    command -v socat &>/dev/null || apt-get install -y socat

    systemctl daemon-reload
    log "Template socat proxy creato"
}

setup_vm_ssh_hook() {
    log "Configurazione hook SSH automatico..."

    # Copy the updated hook (if the current version does not already exist)
    cp "${SCRIPT_DIR}/incus_vm_hook.sh" /mnt/nas2/nas-scripts/incus_vm_hook.sh 2>/dev/null || true
    chmod +x /mnt/nas2/nas-scripts/incus_vm_hook.sh

    # Systemd timer to run the hook every 30 seconds
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
# SSH shortcut to Incus VMs (via socat port forwarding)
# Usage: vm-ssh vmname [commands...]
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

    # Dump the incus configuration
    incus admin sql global "SELECT * FROM config" > "$INCUS_BACKUP_DIR/incus-config.sql" 2>/dev/null || true

    # Export profiles
    incus profile show default > "$INCUS_BACKUP_DIR/profile-default.yaml" 2>/dev/null || true

    # Export network
    incus network show incusbr0 > "$INCUS_BACKUP_DIR/network-incusbr0.yaml" 2>/dev/null || true

    # Export storage
    if [ -n "$storage_pool" ]; then
        incus storage show "$storage_pool" > "$INCUS_BACKUP_DIR/storage-${storage_pool}.yaml" 2>/dev/null || true
    fi

    # List VMs with config
    for vm in $(incus list -f csv -c n 2>/dev/null); do
        incus config show "$vm" --expanded > "$INCUS_BACKUP_DIR/vm-${vm}.yaml"
        log "  Esportata config di $vm"
    done

    # Copy this script and the hooks
    cp "$0" "$INCUS_BACKUP_DIR/setup_incus.sh"
    cp /mnt/nas2/nas-scripts/incus_vm_hook.sh "$INCUS_BACKUP_DIR/" 2>/dev/null || true

    # Export systemd units
    cp /etc/systemd/system/incus-dns-sync.* "$INCUS_BACKUP_DIR/" 2>/dev/null || true
    cp /etc/systemd/system/incus-iptables.service "$INCUS_BACKUP_DIR/" 2>/dev/null || true
    cp /etc/systemd/system/incus-port-proxy@.service "$INCUS_BACKUP_DIR/" 2>/dev/null || true

    # Export port-map and env files
    cp "$PORT_MAP" "$INCUS_BACKUP_DIR/" 2>/dev/null || true
    cp "$PROXY_STATE" "$INCUS_BACKUP_DIR/" 2>/dev/null || true
    cp -r "$PROXY_DIR" "$INCUS_BACKUP_DIR/" 2>/dev/null || true

    log "Config esportata in $INCUS_BACKUP_DIR"
    log "Per backup completo delle VM, usa: incus export <vm-name> $INCUS_BACKUP_DIR/<vm>.tar.gz"
}

restore_config() {
    log "Ripristino configurazione Incus..."

    [ -d "$INCUS_BACKUP_DIR" ] || die "Directory backup non trovata: $INCUS_BACKUP_DIR"

    # Reinstall if needed
    install_incus
    setup_swap

    # Restore from preseed if the profile is present
    if [ -f "$INCUS_BACKUP_DIR/profile-default.yaml" ]; then
        configure_incus
    fi

    # Restore hooks
    if [ -f "$INCUS_BACKUP_DIR/incus_vm_hook.sh" ]; then
        cp "$INCUS_BACKUP_DIR/incus_vm_hook.sh" /mnt/nas2/nas-scripts/
        chmod +x /mnt/nas2/nas-scripts/incus_vm_hook.sh
    fi

    # Restore systemd units
    cp "$INCUS_BACKUP_DIR"/incus-dns-sync.* /etc/systemd/system/ 2>/dev/null || true
    cp "$INCUS_BACKUP_DIR"/incus-iptables.service /etc/systemd/system/ 2>/dev/null || true
    cp "$INCUS_BACKUP_DIR"/incus-port-proxy@.service /etc/systemd/system/ 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable --now incus-dns-sync.timer 2>/dev/null || true
    systemctl enable --now incus-iptables.service 2>/dev/null || true

    # Restore port-map and env files
    cp "$INCUS_BACKUP_DIR/port-map.txt" "$PORT_MAP" 2>/dev/null || true
    cp "$INCUS_BACKUP_DIR/port-proxy-state.txt" "$PROXY_STATE" 2>/dev/null || true
    mkdir -p "$PROXY_DIR"
    cp -r "$INCUS_BACKUP_DIR/port-proxy/." "$PROXY_DIR/" 2>/dev/null || true

    setup_nginx_stream
    setup_le_certs
    setup_trusted_client_certs
    setup_ssh_helper

    # Restore VMs from the export (if present)
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
            [[ "$svc_id" == *--ssh ]] && continue  # already shown above
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

# --- Storage migration: pool with hard quotas (LVM thin, idempotent) ----------

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
    log "Il backing file resta dove Incus lo ha creato: per spostarlo sul disco dati usa relocate-pool."
    log "Per ridimensionare il pool: incus storage set ${INCUS_POOL} size=<new_size>"
}

# --- Relocation of the pool backing file to the data disk (idempotent) --------
# Moves the loop-backing file of the LVM pool from / (system disk) to /mnt/nas
# (data disk) and leaves a symlink at the original path, so the Incus config
# (source:) stays unchanged and the DB is not touched. Idempotent: if the source is
# already a symlink resolving to INCUS_POOL_IMG, it is a no-op.
pool_backing_relocated() {
    local src resolved_target
    src=$(incus storage get "$INCUS_POOL" source 2>/dev/null || true)
    [ -n "$src" ] || return 1
    resolved_target=$(readlink -f "$INCUS_POOL_IMG" 2>/dev/null || echo "$INCUS_POOL_IMG")
    [ "$(readlink -f "$src" 2>/dev/null)" = "$resolved_target" ]
}

relocate_pool_backing_file() {
    log "=== Relocazione backing file pool '${INCUS_POOL}' su disco dati ==="

    if ! incus storage show "$INCUS_POOL" &>/dev/null; then
        die "Pool ${INCUS_POOL} inesistente"
    fi

    local src
    src=$(incus storage get "$INCUS_POOL" source 2>/dev/null || true)
    [ -n "$src" ] || die "Pool ${INCUS_POOL}: campo source vuoto (non loop-backed?)"

    # source must be a file/symlink (loop-backed), not a dedicated block device
    if [ -b "$src" ]; then
        die "source ${src} e' un block device, non un file loop-backed: relocazione non applicabile"
    fi

    if pool_backing_relocated; then
        log "Backing file gia' rilocato: ${src} -> ${INCUS_POOL_IMG} — no-op"
        return 0
    fi

    mountpoint -q /mnt/nas || die "/mnt/nas non montato: impossibile rilocare"

    local realsrc
    realsrc=$(readlink -f "$src")
    [ -f "$realsrc" ] || die "File backing ${realsrc} non trovato"

    local src_bytes free_bytes
    src_bytes=$(du -B1 --apparent-size "$realsrc" | cut -f1)
    log "Backing file: ${src} (reale $(du -h "$realsrc" | cut -f1), apparente $(du -h --apparent-size "$realsrc" | cut -f1))"
    log "Destinazione: ${INCUS_POOL_IMG} (libero su /mnt/nas: $(df -h /mnt/nas | awk 'NR==2{print $4}'))"

    mkdir -p "$INCUS_POOL_IMG_DIR"

    # 1) Stop active VMs (we bring them back up afterwards)
    local running_vms=()
    log "Stop istanze attive..."
    stop_running_instances running_vms

    # 2) Stop the Incus daemon to free the loop device
    log "Stop daemon Incus..."
    incus admin shutdown 2>/dev/null || true
    systemctl stop incus.service 2>/dev/null || true
    systemctl stop incus.socket 2>/dev/null || true
    sleep 3

    # 3) Deactivate the VG and detach the loop device from the source file
    local loopdev
    loopdev=$(losetup -j "$realsrc" 2>/dev/null | cut -d: -f1)
    vgchange -an "$INCUS_POOL" 2>/dev/null || true
    if [ -n "$loopdev" ]; then
        losetup -d "$loopdev" 2>/dev/null || true
        log "Loop ${loopdev} staccato da ${realsrc}"
    fi

    # 4) Sparse-aware copy to the data disk (preserves the holes: does not inflate to 200G)
    if [ -f "$INCUS_POOL_IMG" ]; then
        warn "Destinazione ${INCUS_POOL_IMG} gia' presente: la riutilizzo senza sovrascrivere"
    else
        log "Copia sparse del backing file..."
        cp --sparse=always "$realsrc" "${INCUS_POOL_IMG}.partial"
        sync
        mv "${INCUS_POOL_IMG}.partial" "$INCUS_POOL_IMG"
        log "Copiato: $(du -h "$INCUS_POOL_IMG" | cut -f1) reali su /mnt/nas"
    fi

    # 5) Replace the original with a symlink to the new path
    #    (keep a safety backup of the original file until validated)
    if [ ! -L "$src" ]; then
        mv "$realsrc" "${realsrc}.pre-relocate.bak"
        ln -s "$INCUS_POOL_IMG" "$src"
        log "Symlink creato: ${src} -> ${INCUS_POOL_IMG}"
    fi

    # 6) Restart the Incus daemon (recreates the loop on the symlink, reactivates the VG)
    log "Avvio daemon Incus..."
    systemctl start incus.socket 2>/dev/null || true
    systemctl start incus.service 2>/dev/null || true
    local wait=0
    until incus storage show "$INCUS_POOL" &>/dev/null; do
        sleep 2; wait=$((wait+2))
        [ "$wait" -ge 60 ] && die "Timeout: Incus non risponde dopo la relocazione (backup originale: ${realsrc}.pre-relocate.bak)"
    done

    # 7) Check that the loop now points to the new file
    local newloop
    newloop=$(losetup -j "$INCUS_POOL_IMG" 2>/dev/null | cut -d: -f1)
    [ -n "$newloop" ] || warn "Loop sul nuovo file non rilevato (Incus potrebbe attivarlo on-demand)"
    [ -n "$newloop" ] && log "Loop attivo sul nuovo file: ${newloop} -> ${INCUS_POOL_IMG}"

    # 8) Restart the previously active VMs
    log "Riavvio istanze..."
    restart_instances "${running_vms[@]}"

    log "=== Relocazione completata ==="
    log "Backing file ora su ${INCUS_POOL_IMG} (disco dati 16TB), symlink da ${src}."
    log "Backup dell'originale: ${realsrc}.pre-relocate.bak — rimuovilo dopo aver verificato le VM:"
    log "  sudo rm -f ${realsrc}.pre-relocate.bak"
}

migrate_to_btrfs() {
    warn "migrate_to_btrfs e' deprecato: uso il pool LVM con quote rigide."
    migrate_to_quota_pool
}

# --- Custom volume migration: filesystem → block (idempotent) -----------------
# Block volumes expose the correct size to df in the VM (no virtiofs quirk).

migrate_volumes_to_block() {
    log "=== Migrazione volumi custom a content-type=block ==="

    local pool="$INCUS_POOL"

    # List custom volumes of type filesystem
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

        # Find the VM that uses this volume and the path
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

        # Get the current size
        local vol_size
        vol_size=$(incus storage volume get "$pool" "custom/${vol}" size 2>/dev/null || echo "")
        [ -z "$vol_size" ] && vol_size="20GiB"

        # Stop the VM if needed
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
            # Remove the device from the VM
            log "    Rimuovo device '${device_name}' da ${attached_vm}..."
            incus config device remove "$attached_vm" "$device_name"
        fi

        # Delete the old filesystem volume
        log "    Elimino volume filesystem '${vol}'..."
        incus storage volume delete "$pool" "custom/${vol}"

        # Create the new block volume with the same size
        log "    Creo volume block '${vol}' (${vol_size})..."
        incus storage volume create "$pool" "${vol}" --type block size="${vol_size}"

        # Re-attach to the VM
        if [ -n "$attached_vm" ]; then
            log "    Collego a ${attached_vm} come /dev/sdX..."
            incus config device add "$attached_vm" "$device_name" disk pool="$pool" source="${vol}"
        fi

        # Restart the VM
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

    # Stop and remove
    # Stop all proxies
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

    # Restore self-signed certs if the backups exist
    if [ -f /var/lib/incus/server.crt.selfsigned ] && [ -f /var/lib/incus/server.key.selfsigned ]; then
        rm -f /var/lib/incus/server.crt /var/lib/incus/server.key
        mv /var/lib/incus/server.crt.selfsigned /var/lib/incus/server.crt
        mv /var/lib/incus/server.key.selfsigned /var/lib/incus/server.key
    else
        rm -f /var/lib/incus/server.crt /var/lib/incus/server.key 2>/dev/null
    fi

    log "Incus rimosso. Storage in $INCUS_STORAGE NON cancellato (rimuovilo manualmente se vuoi)."
}

# --- Main ---------------------------------------------------------------------

# Apply the REDACTED_BRAND SSH policy to all RUNNING VMs (idempotent).
# Policy: PasswordAuthentication=yes, PermitRootLogin=no, MaxAuthTries=3.
# Wins over /etc/ssh/sshd_config.d/50-cloud-init.conf thanks to the 01- prefix.
# Assigns no password to any user: the admin chooses who gets one.
fix_vm_ssh_policy() {
    local vm changed total=0 ok=0
    log "Applico policy SSH REDACTED_BRAND a tutte le VM RUNNING..."
    for vm in $(incus list --format csv -c n,s 2>/dev/null | awk -F, '$2=="RUNNING"{print $1}'); do
        total=$((total+1))
        # Push the policy file + legacy cleanup + sshd reload, all idempotent.
        if incus exec "$vm" -- bash -s <<'BASH'; then
set -e
mkdir -p /etc/ssh/sshd_config.d
desired_path=/etc/ssh/sshd_config.d/01-REDACTED_BRAND_lc-defaults.conf
desired_content='# REDACTED_BRAND policy: SSH password auth ENABLED, but by default NO user
# has a password (vm-admin and other cloud-init users are created with
# a locked password). The VM administrator can create users with
# ad-hoc passwords:
#   incus exec <vm> -- useradd -m <user> && incus exec <vm> -- passwd <user>
# Or assign a password to an existing user:
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
# Make sure sshd_config includes the dir (Rocky/RHEL does not by default)
if ! grep -q "^Include /etc/ssh/sshd_config.d" /etc/ssh/sshd_config; then
    sed -i "1iInclude /etc/ssh/sshd_config.d/*.conf" /etc/ssh/sshd_config
    changed=1
fi
# Clean up duplicate directives in the main config that could mask the includes
sed -i "/^PasswordAuthentication /d;/^PermitRootLogin /d" /etc/ssh/sshd_config && true
if [ "$changed" -eq 1 ]; then
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || \
        systemctl restart sshd 2>/dev/null || systemctl restart ssh
fi
# Actual check
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
    relocate-pool)
        [ "$(id -u)" -eq 0 ] || die "Esegui come root: sudo $0 relocate-pool"
        relocate_pool_backing_file
        ;;
    fix-vm-ssh)
        [ "$(id -u)" -eq 0 ] || die "Esegui come root: sudo $0 fix-vm-ssh"
        fix_vm_ssh_policy
        ;;
    *)
        echo "Uso: $0 {install|uninstall|status|export|restore|trust-certs|migrate-storage|migrate-quota-storage|migrate-volumes-block|relocate-pool|fix-vm-ssh}"
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
        echo "  relocate-pool         — Sposta il backing file del pool su /mnt/nas (disco dati) via symlink"
        echo "  fix-vm-ssh            — Applica policy SSH REDACTED_BRAND a tutte le VM RUNNING"
        exit 1
        ;;
esac
