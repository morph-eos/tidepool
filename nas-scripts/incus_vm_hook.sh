#!/usr/bin/env bash
# =============================================================================
# INCUS VM HOOK — Sistema proxy unificato
# Gestisce socat proxy via systemd per TUTTE le porte delle VM Incus
# Chiamato da: incus-dns-sync.timer (ogni 30 secondi)
# =============================================================================
#
# Tutti i proxy sono chiavi user.proxy.<nome>=<host_port>:<vm_port> sulla VM:
#
#   user.proxy.ssh      = 2201:22    (auto-assegnato al provisioning)
#   user.proxy.web      = 8080:80    (configurato dall'utente via UI/CLI)
#   user.proxy.cockpit  = 3001:9090  (configurato dall'utente via UI/CLI)
#
# Visibili e modificabili nella UI Incus: Configuration > Advanced
# Il hook rileva le modifiche e aggiorna i servizi entro 30 secondi.
#
# SSH auto-assignment: range 2201-2299 (skip 2222)
# Porte bannate: < 1000, Docker, 22, 80, 443, 2222
# Servizi: incus-port-proxy@<vm>--<nome>.service
# =============================================================================

# --- Config ---
PROXY_ENV_DIR="/mnt/nas2/incus-vms/port-proxy"
PROXY_STATE="/mnt/nas2/incus-vms/port-proxy-state.txt"
PORT_MAP="/mnt/nas2/incus-vms/port-map.txt"
SSH_PORT_BASE=2201
SSH_PORT_MAX=2299
SSH_PORT_SKIP="2222"
LOG="/var/log/incus-dns.log"

log() { echo "$(date -Is) - $*" >> "$LOG"; }

mkdir -p "$PROXY_ENV_DIR"
[ -f "$PROXY_STATE" ] || touch "$PROXY_STATE"

# --- Migrazione una tantum dal vecchio sistema separato ssh-proxy ---
MIGRATION_FLAG="/mnt/nas2/incus-vms/.proxy-unified"
if [ ! -f "$MIGRATION_FLAG" ]; then
    OLD_SSH_DIR="/mnt/nas2/incus-vms/ssh-proxy"
    if [ -d "$OLD_SSH_DIR" ]; then
        for f in "$OLD_SSH_DIR"/*.env; do
            [ -f "$f" ] || continue
            vm=$(basename "$f" .env)
            systemctl disable --now "incus-ssh-proxy@${vm}.service" 2>/dev/null
            old_port=$(grep "^PORT=" "$f" 2>/dev/null | cut -d= -f2)
            [ -n "$old_port" ] && incus config set "$vm" user.proxy.ssh "${old_port}:22" 2>/dev/null
            log "Migrato SSH legacy: $vm → user.proxy.ssh=${old_port}:22"
        done
        rm -rf "$OLD_SSH_DIR"
    fi
    # Pulizia vecchie chiavi user.ssh-port
    while IFS=',' read -r name _ _; do
        name=$(echo "$name" | xargs)
        [ -z "$name" ] && continue
        incus config unset "$name" user.ssh-port 2>/dev/null
    done < <(incus list -f csv -c ns 2>/dev/null)
    touch "$MIGRATION_FLAG"
    log "Migrazione a proxy unificato completata"
fi

# --- Porte bannate ---
get_banned_ports() {
    local banned="2222 22 80 443"
    local docker_ports
    docker_ports=$(docker ps --format '{{.Ports}}' 2>/dev/null | grep -oP '0\.0\.0\.0:\K[0-9]+' | sort -u)
    for p in $docker_ports; do
        banned="$banned $p"
    done
    echo "$banned"
}

is_port_banned() {
    local port="$1"
    [ "$port" -lt 1000 ] 2>/dev/null && return 0
    local banned; banned=$(get_banned_ports)
    for bp in $banned; do
        [ "$port" = "$bp" ] && return 0
    done
    return 1
}

# --- Helper: lista VM RUNNING con IP del bridge Incus (10.100.x.x) ---
# Output: <name>|<ipv4>  (ipv4 vuoto se non disponibile)
# Usa JSON via jq per gestire correttamente VM con interfacce multiple
# (es. Podman/Docker dentro la VM crea bridge interni 10.88.x, 172.17.x, ecc.)
list_running_vms_with_ip() {
    incus list -f json 2>/dev/null | jq -r '
        .[] | select(.status=="Running") |
        .name as $n |
        ((.state.network // {}) | to_entries[]?.value.addresses[]? |
            select(.family=="inet" and .scope=="global" and (.address | startswith("10.100."))) |
            .address) as $ip |
        "\($n)|\($ip)"
    ' 2>/dev/null
}

# --- Helper: lista TUTTE le VM (anche STOPPED) con stato ---
# Output: <name>|<state>
list_all_vms() {
    incus list -f json 2>/dev/null | jq -r '.[] | "\(.name)|\(.status | ascii_upcase)"' 2>/dev/null
}

# =============================================================================
# SEZIONE 1: Auto-assign user.proxy.ssh per VM RUNNING senza SSH proxy
# =============================================================================
# Raccogli porte SSH già assegnate (anche da VM ferme, per evitare conflitti)
USED_SSH_PORTS="$SSH_PORT_SKIP"
for f in "$PROXY_ENV_DIR"/*--ssh.env; do
    [ -f "$f" ] || continue
    hp=$(grep "^HOST_PORT=" "$f" | cut -d= -f2)
    [ -n "$hp" ] && USED_SSH_PORTS="$USED_SSH_PORTS $hp"
done

VMS_NEEDING_SSH=""
while IFS='|' read -r name state; do
    [ -z "$name" ] && continue
    existing=$(incus config get "$name" user.proxy.ssh 2>/dev/null | tr -d '"'"'")
    if [ -n "$existing" ]; then
        USED_SSH_PORTS="$USED_SSH_PORTS $(echo "$existing" | cut -d: -f1)"
    elif [ "$state" = "RUNNING" ]; then
        VMS_NEEDING_SSH="$VMS_NEEDING_SSH $name"
    fi
done < <(list_all_vms)

for name in $VMS_NEEDING_SSH; do
    PORT=""
    p=$SSH_PORT_BASE
    while [ $p -le $SSH_PORT_MAX ]; do
        in_use=false
        for u in $USED_SSH_PORTS; do
            [ "$p" = "$u" ] && { in_use=true; break; }
        done
        $in_use || { PORT=$p; break; }
        p=$((p + 1))
    done
    if [ -z "$PORT" ]; then
        log "ERRORE: nessuna porta SSH per $name (range 2201-2299 pieno)"
        continue
    fi
    incus config set "$name" user.proxy.ssh "${PORT}:22"
    USED_SSH_PORTS="$USED_SSH_PORTS $PORT"
    log "SSH auto-assegnato: ${name} → user.proxy.ssh=${PORT}:22"
done

# =============================================================================
# SEZIONE 1.5: Auto-discover servizi in listen (range 3000-3099)
# =============================================================================
# Per ogni VM RUNNING scopre le porte TCP in listen (escluso 22 + loopback).
# Strategia di mapping:
#   - se vm_port è 3000-3099 e libera sull'host → host_port = vm_port (stessa porta)
#   - altrimenti → prima porta libera nel range 3000-3099
# Le chiavi proxy create hanno prefisso "user.proxy.auto-<vmport>" per essere
# distinguibili (e ricreabili/rimovibili). La SEZIONE 2 le instanzia come socat.
# Cattura anche docker-proxy/podman rootless-port (visibili a ss come listener).

AUTO_PORT_MIN=3000
AUTO_PORT_MAX=3099

# Lista porte 3000-3099 in uso sull'host: proxy esistenti di TUTTE le VM + bind di sistema
collect_used_auto_ports() {
    local used=""
    while IFS='|' read -r vname _; do
        [ -z "$vname" ] && continue
        while IFS= read -r line; do
            v=$(echo "$line" | sed -E 's/^[^:]+:[[:space:]]*//' | tr -d '"'"'")
            hp=$(echo "$v" | cut -d: -f1)
            [[ "$hp" =~ ^[0-9]+$ ]] && [ "$hp" -ge "$AUTO_PORT_MIN" ] && [ "$hp" -le "$AUTO_PORT_MAX" ] && used="$used $hp"
        done < <(incus config show "$vname" 2>/dev/null | grep "^[[:space:]]*user\.proxy\.")
    done < <(list_all_vms)
    while read -r p; do
        [ -n "$p" ] && used="$used $p"
    done < <(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | awk -v lo=$AUTO_PORT_MIN -v hi=$AUTO_PORT_MAX '$1>=lo && $1<=hi')
    echo "$used"
}

_in_list() {
    local p="$1" list="$2"
    for u in $list; do [ "$u" = "$p" ] && return 0; done
    return 1
}

while IFS='|' read -r name ipv4; do
    [ -z "$name" ] || [ -z "$ipv4" ] && continue

    # Porte in listen dentro la VM, esclusi loopback (127.x, ::1) e porta 22
    # NB: </dev/null per evitare che incus exec consumi lo stdin del while-loop
    LISTEN_PORTS=$(incus exec "$name" -- ss -tlnH </dev/null 2>/dev/null | awk '{
        addr=$4; n=split(addr, parts, ":"); port=parts[n]; ip="";
        for (i=1; i<n; i++) { ip=ip parts[i]; if (i<n-1) ip=ip":" }
        # Strip trailing %iface (es. 127.0.0.53%lo)
        sub(/%.*/, "", ip)
        if (ip != "" && ip !~ /^127\./ && ip != "[::1]" && ip != "::1") print port
    }' | sort -un | grep -v '^22$')

    # Auto-* esistenti su questa VM (estrai numeri vm_port dopo "auto-")
    EXISTING_AUTO=$(incus config show "$name" </dev/null 2>/dev/null | \
        grep -oE '^[[:space:]]*user\.proxy\.auto-[0-9]+' | sed 's/.*auto-//' | sort -un)

    # Rimuovi auto-* per porte non più in listen
    for old_vp in $EXISTING_AUTO; do
        if ! echo "$LISTEN_PORTS" | grep -q "^${old_vp}$"; then
            incus config unset "$name" "user.proxy.auto-${old_vp}" </dev/null 2>/dev/null
            log "Auto-discovery: rimosso ${name}/auto-${old_vp} (servizio non piu in listen)"
        fi
    done

    # Aggiungi auto-* per nuove porte in listen
    USED_AUTO=$(collect_used_auto_ports)
    for vp in $LISTEN_PORTS; do
        # Skip se già coperta da QUALUNQUE user.proxy.* (verifica vm_port esistente)
        already=$(incus config show "$name" </dev/null 2>/dev/null | grep "^[[:space:]]*user\.proxy\." | \
            sed -E 's/^[^:]+:[[:space:]]*//' | tr -d '"'"'" | awk -F: -v vp="$vp" '$2==vp' | head -1)
        [ -n "$already" ] && continue

        chosen=""
        if [ "$vp" -ge "$AUTO_PORT_MIN" ] 2>/dev/null && [ "$vp" -le "$AUTO_PORT_MAX" ] 2>/dev/null; then
            _in_list "$vp" "$USED_AUTO" || chosen="$vp"
        fi
        if [ -z "$chosen" ]; then
            for cand in $(seq $AUTO_PORT_MIN $AUTO_PORT_MAX); do
                if ! _in_list "$cand" "$USED_AUTO"; then
                    chosen="$cand"; break
                fi
            done
        fi
        if [ -z "$chosen" ]; then
            log "WARN: range ${AUTO_PORT_MIN}-${AUTO_PORT_MAX} pieno, skip ${name}/vm:${vp}"
            break
        fi
        incus config set "$name" "user.proxy.auto-${vp}" "${chosen}:${vp}" </dev/null 2>/dev/null
        USED_AUTO="$USED_AUTO $chosen"
        log "Auto-discovery: ${name} VM:${vp} → host:${chosen}"
    done
done < <(list_running_vms_with_ip)

# =============================================================================
# SEZIONE 2: Processa TUTTI i user.proxy.* (SSH + custom) uniformemente
# =============================================================================
ACTIVE_PROXIES=$(mktemp)

while IFS='|' read -r name ipv4; do
    [ -z "$name" ] || [ -z "$ipv4" ] && continue

    while IFS= read -r config_line; do
        # Parsing robusto: "  user.proxy.ssh: \"2202:22\""
        key=$(echo "$config_line" | sed -E 's/^[[:space:]]*([^:]+):.*/\1/')
        value=$(echo "$config_line" | sed -E 's/^[^:]+:[[:space:]]*//' | tr -d '"'"'")
        [ -z "$key" ] || [ -z "$value" ] && continue
        svc_name=$(echo "$key" | sed 's/^user\.proxy\.//')
        host_port=$(echo "$value" | cut -d: -f1)
        vm_port=$(echo "$value" | cut -d: -f2)
        [ -z "$host_port" ] || [ -z "$vm_port" ] && continue

        svc_id="${name}--${svc_name}"

        # Verifica porta bannata
        if is_port_banned "$host_port"; then
            log "BLOCCATO: ${name}/user.proxy.${svc_name} porta ${host_port} non consentita — rimossa"
            incus config unset "$name" "user.proxy.${svc_name}" 2>/dev/null
            systemctl disable --now "incus-port-proxy@${svc_id}.service" 2>/dev/null
            rm -f "${PROXY_ENV_DIR}/${svc_id}.env"
            continue
        fi

        echo "$svc_id" >> "$ACTIVE_PROXIES"

        # Già attivo e corretto?
        if [ -f "${PROXY_ENV_DIR}/${svc_id}.env" ] && systemctl is-active --quiet "incus-port-proxy@${svc_id}.service"; then
            current_hp=$(grep "^HOST_PORT=" "${PROXY_ENV_DIR}/${svc_id}.env" 2>/dev/null | cut -d= -f2)
            current_vp=$(grep "^VM_PORT=" "${PROXY_ENV_DIR}/${svc_id}.env" 2>/dev/null | cut -d= -f2)
            current_ip=$(grep "^VM_IP=" "${PROXY_ENV_DIR}/${svc_id}.env" 2>/dev/null | cut -d= -f2)
            if [ "$current_hp" = "$host_port" ] && [ "$current_vp" = "$vm_port" ] && [ "$current_ip" = "$ipv4" ]; then
                continue
            fi
            log "Aggiornamento proxy: ${svc_id} → ${host_port}:${vm_port}"
        fi

        cat > "${PROXY_ENV_DIR}/${svc_id}.env" << EOF
HOST_PORT=${host_port}
VM_PORT=${vm_port}
VM_IP=${ipv4}
EOF
        chmod 644 "${PROXY_ENV_DIR}/${svc_id}.env"

        systemctl daemon-reload
        systemctl enable --now "incus-port-proxy@${svc_id}.service" 2>/dev/null
        systemctl restart "incus-port-proxy@${svc_id}.service" 2>/dev/null
        log "Proxy avviato: ${name}/${svc_name} host:${host_port} → VM:${ipv4}:${vm_port}"

    done < <(incus config show "$name" 2>/dev/null | grep "^[[:space:]]*user\.proxy\.")
done < <(list_running_vms_with_ip)

# =============================================================================
# SEZIONE 3: Pulizia proxy rimossi o VM ferme/cancellate
# =============================================================================
if [ -f "$PROXY_STATE" ]; then
    while read -r old_svc_id; do
        [ -z "$old_svc_id" ] && continue
        if ! grep -q "^${old_svc_id}$" "$ACTIVE_PROXIES" 2>/dev/null; then
            systemctl disable --now "incus-port-proxy@${old_svc_id}.service" 2>/dev/null
            rm -f "${PROXY_ENV_DIR}/${old_svc_id}.env"
            log "Proxy rimosso: ${old_svc_id}"
        fi
    done < "$PROXY_STATE"
fi

cp "$ACTIVE_PROXIES" "$PROXY_STATE"
chmod 644 "$PROXY_STATE"
rm -f "$ACTIVE_PROXIES"

# =============================================================================
# SEZIONE 4: Ricostruisci port-map.txt (compatibilità vm-ssh)
# =============================================================================
TEMP_MAP=$(mktemp)
while IFS='|' read -r name state; do
    [ "$state" = "RUNNING" ] || continue
    ssh_val=$(incus config get "$name" user.proxy.ssh 2>/dev/null | tr -d '"'"'")
    [ -n "$ssh_val" ] || continue
    ssh_port=$(echo "$ssh_val" | cut -d: -f1)
    echo "${name}:${ssh_port}" >> "$TEMP_MAP"
done < <(list_all_vms)
mv "$TEMP_MAP" "$PORT_MAP"
chmod 644 "$PORT_MAP"

# =============================================================================
# SEZIONE 5: MOTD dinamico + comando vm-proxies nelle VM
# =============================================================================
# Per ogni VM RUNNING:
#   1. Scrive /usr/local/bin/vm-proxies (script standalone con dati embedded
#      raccolti dall'host: hostname, OS info, lista proxy)
#   2. Scrive /etc/motd con l'output dello script (mostrato al login interattivo)
# Aggiornato ogni 30s dal hook. L'utente puo' rilanciare `vm-proxies` in
# qualsiasi momento per rivedere lo stato (snapshot dell'ultimo refresh).
# Funziona su Rocky/RHEL/Debian/Ubuntu (PAM motd legge /etc/motd di default).

PUBLIC_HOST="vm.REDACTED_HOSTNAME.REDACTED_DDNS"

while IFS='|' read -r name ipv4; do
    [ -z "$name" ] && continue

    # Raccogli proxy ordinati per host_port (numerico)
    proxies_data=""
    while IFS= read -r line; do
        key=$(echo "$line" | sed -E 's/^[[:space:]]*([^:]+):.*/\1/')
        val=$(echo "$line" | sed -E 's/^[^:]+:[[:space:]]*//' | tr -d '"'"'")
        svc=$(echo "$key" | sed 's/^user\.proxy\.//')
        hp=$(echo "$val" | cut -d: -f1)
        vp=$(echo "$val" | cut -d: -f2)
        [ -z "$hp" ] || [ -z "$vp" ] && continue
        case "$svc" in
            ssh)    kind="SSH" ;;
            auto-*) kind="auto-discovered" ;;
            *)      kind="manual" ;;
        esac
        proxies_data="${proxies_data}${hp}|${svc}|${vp}|${kind}"$'\n'
    done < <(incus config show "$name" </dev/null 2>/dev/null | grep "^[[:space:]]*user\.proxy\.")

    # Ordina per host_port numerico
    proxies_sorted=$(echo "$proxies_data" | grep -v '^$' | sort -t'|' -k1,1n)

    # Costruisci tabella formattata. Marca con * i proxy raggiungibili da Internet (3000-3099).
    if [ -n "$proxies_sorted" ]; then
        rows=$(echo "$proxies_sorted" | awk -F'|' '{
            mark = ($1 >= 3000 && $1 <= 3099) ? "*" : " "
            printf "  %s %-15s  host:%-6s -> VM:%-6s  (%s)\n", mark, $2, $1, $3, $4
        }')
    else
        rows="    (no proxies currently active)"
    fi

    # Genera lo script /usr/local/bin/vm-proxies (dati embedded come heredoc)
    script=$(cat <<SCRIPT
#!/usr/bin/env bash
# vm-proxies — show NAS host proxies forwarding traffic to this VM.
# Auto-generated by NAS Incus hook (refreshed every 30s). Snapshot is
# accurate as of the timestamp below; rerun this command for an update.
#
# Generated: $(date -Iseconds)

# --- VM identity (collected at generation time on the NAS host) ---
VM_NAME="${name}"
VM_IP_INTERNAL="${ipv4}"
PUBLIC_HOST="${PUBLIC_HOST}"

# --- Live VM info (collected when you run this command) ---
HOSTNAME_NOW=\$(hostname 2>/dev/null || echo unknown)
OS_PRETTY=\$(. /etc/os-release 2>/dev/null && echo "\${PRETTY_NAME:-unknown}")
KERNEL=\$(uname -sr 2>/dev/null || echo unknown)
UPTIME=\$(uptime -p 2>/dev/null | sed 's/^up //' || echo unknown)
LOGGED_IN=\$(who 2>/dev/null | wc -l)
LOAD=\$(awk '{print \$1, \$2, \$3}' /proc/loadavg 2>/dev/null || echo "n/a")
MEM=\$(free -h 2>/dev/null | awk '/^Mem:/ {print \$3 " / " \$2}')
DISK=\$(df -h / 2>/dev/null | awk 'NR==2 {print \$3 " / " \$2 " (" \$5 " used)"}')

cat <<BANNER
================================================================
  Welcome to "\${VM_NAME}" — Incus VM on NAS (host: \${PUBLIC_HOST})
================================================================
  OS:        \${OS_PRETTY}
  Kernel:    \${KERNEL}
  Hostname:  \${HOSTNAME_NOW}
  Uptime:    \${UPTIME}
  Load avg:  \${LOAD}
  Memory:    \${MEM}
  Disk /:    \${DISK}
  Sessions:  \${LOGGED_IN} active

----------------------------------------------------------------
  HOST PROXY FORWARDING (this VM → published on NAS host)
----------------------------------------------------------------
How it works:
  - The NAS hook scans every 30s the TCP ports listening inside
    this VM ("ss -tlnH") and creates a socat proxy on the NAS
    host so the service is reachable from outside.
  - Port range 2201-2299 is reserved for SSH (internal access
    via "vm-ssh \${VM_NAME}" from the NAS).
  - Port range 3000-3099 is open on the home router/firewall
    and reachable as \${PUBLIC_HOST}:<port> from the Internet.
  - If a VM port is already in 3000-3099 and free on the host,
    it is mapped to the SAME number; otherwise to the next free
    one in 3000-3099.
  - When a service stops listening, its proxy is removed within
    30 seconds.

Active proxies (* = reachable from Internet at \${PUBLIC_HOST}:<host_port>):
${rows}

Manage proxies (run on the NAS host):
  incus config set   \${VM_NAME} user.proxy.<name> <hostport>:<vmport>
  incus config unset \${VM_NAME} user.proxy.<name>

To refresh this view (snapshot is up to ~30s old):
  vm-proxies
================================================================
BANNER
SCRIPT
)

    # Push script
    tmpf=$(mktemp)
    echo "$script" > "$tmpf"
    new_md5=$(md5sum "$tmpf" | awk '{print $1}')
    cur_md5=$(incus exec "$name" -- md5sum /usr/local/bin/vm-proxies </dev/null 2>/dev/null | awk '{print $1}')
    if [ "$cur_md5" != "$new_md5" ]; then
        if incus file push --quiet --mode 0755 --uid 0 --gid 0 "$tmpf" "${name}/usr/local/bin/vm-proxies" </dev/null 2>/dev/null; then
            # Genera /etc/motd eseguendo lo script appena pushato (così MOTD == output del comando)
            motd=$(incus exec "$name" -- /usr/local/bin/vm-proxies </dev/null 2>/dev/null)
            if [ -n "$motd" ]; then
                tmpm=$(mktemp)
                echo "$motd" > "$tmpm"
                incus file push --quiet --mode 0644 --uid 0 --gid 0 "$tmpm" "${name}/etc/motd" </dev/null 2>/dev/null
                rm -f "$tmpm"
            fi
            log "MOTD/vm-proxies aggiornato in ${name}"
        fi
    fi
    rm -f "$tmpf"
done < <(list_running_vms_with_ip)
