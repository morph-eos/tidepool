#!/usr/bin/env bash
# =============================================================================
# INCUS VM HOOK — unified proxy system
# Manages socat proxies via systemd for ALL the ports of the Incus VMs
# Called by: incus-dns-sync.timer (every 30 seconds)
# =============================================================================
#
# All proxies are user.proxy.<name>=<host_port>:<vm_port> keys on the VM:
#
#   user.proxy.ssh      = 2201:22    (auto-assigned at provisioning)
#   user.proxy.web      = 8080:80    (configured by the user via UI/CLI)
#   user.proxy.cockpit  = 3001:9090  (configured by the user via UI/CLI)
#
# Visible and editable in the Incus UI: Configuration > Advanced
# The hook detects the changes and updates the services within 30 seconds.
#
# SSH auto-assignment: range 2201-2299 (skip 2222, the host's own sshd)
# Banned ports: < 1000, Docker, 22, 2222, 80, 443
# Services: incus-port-proxy@<vm>--<name>.service
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

# --- One-time migration from the old separate ssh-proxy system ---
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
    # Clean up old user.ssh-port keys
    while IFS=',' read -r name _ _; do
        name=$(echo "$name" | xargs)
        [ -z "$name" ] && continue
        incus config unset "$name" user.ssh-port 2>/dev/null
    done < <(incus list -f csv -c ns 2>/dev/null)
    touch "$MIGRATION_FLAG"
    log "Migrazione a proxy unificato completata"
fi

# --- Banned ports ---
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

# --- Helper: list RUNNING VMs with a reachable IP ---
# Output: <name>|<ipv4>  (ipv4 empty if unavailable)
# Strategy: prefer the Incus bridge IP (10.100.x.x), fall back to any
# global non-loopback/non-link-local IP reachable from the host.
# This makes the proxy resilient to nmcli/dhcp errors inside the VM.
list_running_vms_with_ip() {
    incus list -f json 2>/dev/null | jq -r '
        .[] | select(.status=="Running") |
        .name as $n |
        # Collect all the global IPs of the VM (excludes loopback, link-local, docker/podman bridges)
        [ (.state.network // {}) | to_entries[]?.value.addresses[]? |
            select(.family=="inet" and .scope=="global") | .address ] as $all |
        # Prefer 10.100.x.x (Incus bridge), then any non-172.x/10.88.x IP (internal docker)
        ( ($all | map(select(startswith("10.100."))) | first // null) //
          ($all | map(select(startswith("10.100.") or startswith("172.") or startswith("10.88.")) | not) | first // null) //
          ($all | first // null)
        ) as $ip |
        select($ip != null) |
        "\($n)|\($ip)"
    ' 2>/dev/null
}

# --- Helper: list ALL VMs (also STOPPED) with their state ---
# Output: <name>|<state>
list_all_vms() {
    incus list -f json 2>/dev/null | jq -r '.[] | "\(.name)|\(.status | ascii_upcase)"' 2>/dev/null
}

# =============================================================================
# SECTION 1: Auto-assign user.proxy.ssh for RUNNING VMs without an SSH proxy
# =============================================================================
# Collect the SSH ports already assigned (also from stopped VMs, to avoid conflicts)
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
# SECTION 1.5: Auto-discover listening services (range 3000-3099)
# =============================================================================
# For each RUNNING VM, discover the listening TCP ports (excluding 22 + loopback).
# Mapping strategy:
#   - if vm_port is 3000-3099 and free on the host → host_port = vm_port (same port)
#   - otherwise → first free port in the 3000-3099 range
# The proxy keys created have the prefix "user.proxy.auto-<vmport>" so they are
# distinguishable (and recreatable/removable). SECTION 2 instantiates them as socat.
# Also catches docker-proxy/podman rootless-port (visible to ss as listeners).

AUTO_PORT_MIN=3000
AUTO_PORT_MAX=3099

# List the 3000-3099 ports in use on the host: existing proxies of ALL VMs + system binds
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

    # Listening ports inside the VM, excluding loopback (127.x, ::1) and port 22
    # NB: </dev/null to prevent incus exec from consuming the while-loop's stdin
    LISTEN_PORTS=$(incus exec "$name" -- ss -tlnH </dev/null 2>/dev/null | awk '{
        addr=$4; n=split(addr, parts, ":"); port=parts[n]; ip="";
        for (i=1; i<n; i++) { ip=ip parts[i]; if (i<n-1) ip=ip":" }
        # Strip trailing %iface (e.g. 127.0.0.53%lo)
        sub(/%.*/, "", ip)
        if (ip != "" && ip !~ /^127\./ && ip != "[::1]" && ip != "::1") print port
    }' | sort -un | grep -v '^22$')

    # Existing auto-* on this VM (extract the vm_port numbers after "auto-")
    EXISTING_AUTO=$(incus config show "$name" </dev/null 2>/dev/null | \
        grep -oE '^[[:space:]]*user\.proxy\.auto-[0-9]+' | sed 's/.*auto-//' | sort -un)

    # Remove auto-* for ports no longer listening
    for old_vp in $EXISTING_AUTO; do
        if ! echo "$LISTEN_PORTS" | grep -q "^${old_vp}$"; then
            incus config unset "$name" "user.proxy.auto-${old_vp}" </dev/null 2>/dev/null
            log "Auto-discovery: rimosso ${name}/auto-${old_vp} (servizio non piu in listen)"
        fi
    done

    # Add auto-* for new listening ports
    USED_AUTO=$(collect_used_auto_ports)
    for vp in $LISTEN_PORTS; do
        # Skip if already covered by ANY user.proxy.* (check the existing vm_port)
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
# SECTION 2: Process ALL user.proxy.* (SSH + custom) uniformly
# =============================================================================
ACTIVE_PROXIES=$(mktemp)

while IFS='|' read -r name ipv4; do
    [ -z "$name" ] || [ -z "$ipv4" ] && continue

    while IFS= read -r config_line; do
        # Robust parsing: "  user.proxy.ssh: \"2202:22\""
        key=$(echo "$config_line" | sed -E 's/^[[:space:]]*([^:]+):.*/\1/')
        value=$(echo "$config_line" | sed -E 's/^[^:]+:[[:space:]]*//' | tr -d '"'"'")
        [ -z "$key" ] || [ -z "$value" ] && continue
        svc_name=$(echo "$key" | sed 's/^user\.proxy\.//')
        host_port=$(echo "$value" | cut -d: -f1)
        vm_port=$(echo "$value" | cut -d: -f2)
        [ -z "$host_port" ] || [ -z "$vm_port" ] && continue

        svc_id="${name}--${svc_name}"

        # Check for a banned port
        if is_port_banned "$host_port"; then
            log "BLOCCATO: ${name}/user.proxy.${svc_name} porta ${host_port} non consentita — rimossa"
            incus config unset "$name" "user.proxy.${svc_name}" 2>/dev/null
            systemctl disable --now "incus-port-proxy@${svc_id}.service" 2>/dev/null
            rm -f "${PROXY_ENV_DIR}/${svc_id}.env"
            continue
        fi

        echo "$svc_id" >> "$ACTIVE_PROXIES"

        # Already active and correct?
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
# SECTION 3: Clean up removed proxies or stopped/deleted VMs
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
# SECTION 4: Rebuild port-map.txt (vm-ssh compatibility)
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
# SECTION 5: Dynamic MOTD + vm-proxies command in the VMs
# =============================================================================
# For each RUNNING VM:
#   1. Writes /usr/local/bin/vm-proxies (standalone script with data embedded
#      collected from the host: hostname, OS info, proxy list)
#   2. Writes /etc/motd with the script's output (shown at interactive login)
# Updated every 30s by the hook. The user can rerun `vm-proxies` at
# any time to review the state (snapshot of the last refresh).
# Works on Rocky/RHEL/Debian/Ubuntu (PAM motd reads /etc/motd by default).

PUBLIC_HOST="vm.REDACTED_HOSTNAME.REDACTED_DDNS"

while IFS='|' read -r name ipv4; do
    [ -z "$name" ] && continue

    # Collect proxies sorted by host_port (numeric)
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

    # Sort by numeric host_port
    proxies_sorted=$(echo "$proxies_data" | grep -v '^$' | sort -t'|' -k1,1n)

    # Build a formatted table. Mark with * the proxies reachable from the Internet (3000-3099).
    if [ -n "$proxies_sorted" ]; then
        rows=$(echo "$proxies_sorted" | awk -F'|' '{
            mark = ($1 >= 3000 && $1 <= 3099) ? "*" : " "
            printf "  %s %-15s  host:%-6s -> VM:%-6s  (%s)\n", mark, $2, $1, $3, $4
        }')
    else
        rows="    (no proxies currently active)"
    fi

    # Generate the /usr/local/bin/vm-proxies script (data embedded as a heredoc)
    script=$(cat <<SCRIPT
#!/usr/bin/env bash
# vm-proxies — show NAS host proxies forwarding traffic to this VM.
# Auto-generated by NAS Incus hook (regenerated only when the proxy list
# changes, checked every 30s). No timestamp on purpose: the hook compares
# md5 sums to decide whether to push a new copy into the VM.
#
# Usage:
#   vm-proxies            show VM info + active proxies (default)
#   vm-proxies --help     show full explanation of the proxy logic
#   vm-proxies --motd     short banner for /etc/motd (used by the hook)

# --- VM identity (collected at generation time on the NAS host) ---
VM_NAME="${name}"
PUBLIC_HOST="${PUBLIC_HOST}"

show_help() {
    cat <<HELP
vm-proxies — manage and inspect NAS host port-forwarding for this VM.

WHAT IT DOES
  The NAS host (running Incus) watches every 30s the TCP ports listening
  inside this VM and automatically creates a socat proxy so the service
  becomes reachable from outside the VM.

PORT RANGES
  2201-2299   SSH only. Each VM gets one auto-assigned host port mapped
              to its port 22. Reachable from the NAS as
                ssh -p <port> user@127.0.0.1   (or "vm-ssh \${VM_NAME}")
  3000-3099   General services. These ports are open on the home
              router/firewall, so any service in this range is reachable
              from the Internet as
                \${PUBLIC_HOST}:<host_port>
              Mapping strategy:
                - if the VM listens on a port already in 3000-3099 and
                  that port is free on the NAS host -> SAME number;
                - otherwise -> first free port in 3000-3099.
  Other      Manual mappings only (see "user.proxy.<name>" config keys).

LIFECYCLE
  - Service appears (port starts listening)  -> proxy added within 30s
  - Service disappears (port stops listening) -> proxy removed within 30s
  - VM stopped/deleted                        -> all proxies removed

INSPECT (inside the VM)
  vm-proxies          short status (VM info + table of active proxies)
  vm-proxies --help   this help

MANAGE (must be run on the NAS host, not inside the VM)
  incus config set   \${VM_NAME} user.proxy.<name> <hostport>:<vmport>
  incus config unset \${VM_NAME} user.proxy.<name>

The vm-proxies command and /etc/motd are regenerated by the NAS hook
every 30 seconds; data is at most ~30s stale.
HELP
}

show_status() {
    local HOSTNAME_NOW OS_PRETTY KERNEL UPTIME LOGGED_IN LOAD MEM DISK
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
Active proxies (* = reachable from Internet at \${PUBLIC_HOST}:<host_port>):
${rows}
Run 'vm-proxies --help' for the full explanation of how proxies work.
================================================================
BANNER
}

show_motd() {
    local HOSTNAME_NOW OS_PRETTY UPTIME
    HOSTNAME_NOW=\$(hostname 2>/dev/null || echo unknown)
    OS_PRETTY=\$(. /etc/os-release 2>/dev/null && echo "\${PRETTY_NAME:-unknown}")
    UPTIME=\$(uptime -p 2>/dev/null | sed 's/^up //' || echo unknown)
    cat <<BANNER
================================================================
  Welcome to "\${VM_NAME}" (\${HOSTNAME_NOW}) — Incus VM on NAS
  OS: \${OS_PRETTY}    Up: \${UPTIME}
----------------------------------------------------------------
  Public host:  \${PUBLIC_HOST}   (ports 3000-3099 open from Internet)

  Run 'vm-proxies'         for VM status + active proxies
  Run 'vm-proxies --help'  for the full proxy logic explanation
================================================================
BANNER
}

case "\${1:-}" in
    --help|-h|help) show_help ;;
    --motd)         show_motd ;;
    "")             show_status ;;
    *)              echo "Unknown option: \$1" >&2; show_help; exit 2 ;;
esac
SCRIPT
)

    # Push script
    tmpf=$(mktemp)
    echo "$script" > "$tmpf"
    new_md5=$(md5sum "$tmpf" | awk '{print $1}')
    cur_md5=$(incus exec "$name" -- md5sum /usr/local/bin/vm-proxies </dev/null 2>/dev/null | awk '{print $1}')
    if [ "$cur_md5" != "$new_md5" ]; then
        if incus file push --quiet --mode 0755 --uid 0 --gid 0 "$tmpf" "${name}/usr/local/bin/vm-proxies" </dev/null 2>/dev/null; then
            # /etc/motd = output of "vm-proxies --motd" (synthetic banner)
            motd=$(incus exec "$name" -- /usr/local/bin/vm-proxies --motd </dev/null 2>/dev/null)
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
