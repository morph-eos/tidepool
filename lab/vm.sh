#!/usr/bin/env bash
# =============================================================================
# lab/vm.sh — throwaway QEMU/KVM virtual machines for the tidepool experiments
#
# Needs only qemu-system-x86_64, qemu-img, python3, curl and ssh: no root, no
# libvirt, no ISO tools. The guest gets its cloud-init seed over HTTP from the
# host (NoCloud "net" datasource), and is reached through forwarded localhost
# ports (QEMU user-mode networking).
#
# Everything the VMs need lives outside the repository, in $TIDEPOOL_LAB
# (default ~/lab/tidepool):
#   base/<image>          downloaded cloud image (read-only backing file)
#   vms/<name>/           per-VM disk overlay, env file, pid, serial log
#
# Usage:
#   lab/vm.sh create   <name> [--cpus N] [--mem MB] [--disk GB]
#   lab/vm.sh start    <name>
#   lab/vm.sh stop     <name>
#   lab/vm.sh ssh      <name> [command...]
#   lab/vm.sh snapshot <name> <tag>       (VM must be stopped)
#   lab/vm.sh restore  <name> <tag>       (VM must be stopped)
#   lab/vm.sh destroy  <name>
#   lab/vm.sh list
#   lab/vm.sh console  <name>             (tail the serial log)
# =============================================================================
set -euo pipefail

LAB="${TIDEPOOL_LAB:-$HOME/lab/tidepool}"
IMAGE_URL="${TIDEPOOL_IMAGE_URL:-https://cloud-images.ubuntu.com/releases/noble/release}"
IMAGE_NAME="${TIDEPOOL_IMAGE_NAME:-ubuntu-24.04-server-cloudimg-amd64.img}"
BASE="$LAB/base/$IMAGE_NAME"
SSH_KEY_PUB="${TIDEPOOL_SSH_KEY:-$HOME/.ssh/id_ed25519.pub}"
GUEST_USER="lab"
PORT_BASE=2200

die() { echo "error: $*" >&2; exit 1; }
log() { echo "[lab] $*"; }

vm_dir() { echo "$LAB/vms/$1"; }
need_vm() { [ -d "$(vm_dir "$1")" ] || die "no such VM: $1"; }
load_env() { need_vm "$1"; # shellcheck disable=SC1090
    . "$(vm_dir "$1")/env"; }
is_running() {
    local pf; pf="$(vm_dir "$1")/qemu.pid"
    [ -f "$pf" ] && kill -0 "$(cat "$pf")" 2>/dev/null
}

fetch_base() {
    mkdir -p "$LAB/base"
    if [ ! -f "$BASE" ]; then
        log "downloading $IMAGE_NAME"
        curl -fSL -o "$BASE.part" "$IMAGE_URL/$IMAGE_NAME"
        mv "$BASE.part" "$BASE"
    fi
    # Verify against the published checksum (best effort: the file is replaced on every release)
    if curl -fsSL "$IMAGE_URL/SHA256SUMS" -o "$LAB/base/SHA256SUMS" 2>/dev/null; then
        local want have
        want=$(grep " \*$IMAGE_NAME\$" "$LAB/base/SHA256SUMS" | cut -d' ' -f1 || true)
        have=$(sha256sum "$BASE" | cut -d' ' -f1)
        if [ -n "$want" ] && [ "$want" != "$have" ]; then
            log "warning: image checksum differs from the published one (a newer release?)"
        fi
    fi
}

next_port() {
    local p=$PORT_BASE used
    used=$(grep -h '^SSH_PORT=' "$LAB"/vms/*/env 2>/dev/null | cut -d= -f2 || true)
    while echo "$used" | grep -qx "$p"; do p=$((p + 10)); done
    echo "$p"
}

cmd_create() {
    local name="${1:?name required}"; shift || true
    local cpus=4 mem=6144 disk=40
    while [ $# -gt 0 ]; do
        case "$1" in
            --cpus) cpus="$2"; shift 2 ;;
            --mem)  mem="$2"; shift 2 ;;
            --disk) disk="$2"; shift 2 ;;
            *) die "unknown option: $1" ;;
        esac
    done
    local d; d="$(vm_dir "$name")"
    [ ! -e "$d" ] || die "VM already exists: $name"
    [ -r "$SSH_KEY_PUB" ] || die "SSH public key not found: $SSH_KEY_PUB"
    fetch_base
    mkdir -p "$d/seed"
    qemu-img create -q -f qcow2 -F qcow2 -b "$BASE" "$d/disk.qcow2" "${disk}G"
    local port; port=$(next_port)
    cat > "$d/env" <<EOF
NAME=$name
CPUS=$cpus
MEM=$mem
SSH_PORT=$port
HTTP_PORT=$((port + 1))
HTTPS_PORT=$((port + 2))
EOF
    cat > "$d/seed/meta-data" <<EOF
instance-id: tidepool-$name-$(date +%s)
local-hostname: $name
EOF
    cat > "$d/seed/user-data" <<EOF
#cloud-config
users:
  - name: $GUEST_USER
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - $(cat "$SSH_KEY_PUB")
package_update: false
ssh_pwauth: false
EOF
    log "created $name (ssh on localhost:$port). Start it with: lab/vm.sh start $name"
}

serve_seed() { # serve_seed <dir> <port> -> starts a background HTTP server, prints its pid
    (cd "$1" && exec python3 -m http.server "$2" --bind 127.0.0.1 >/dev/null 2>&1) &
    echo $!
}

cmd_start() {
    local name="${1:?name required}"
    load_env "$name"
    is_running "$name" && { log "$name is already running"; return 0; }
    local d; d="$(vm_dir "$name")"
    local seed_port=$((SSH_PORT + 9)) seed_pid
    seed_pid=$(serve_seed "$d/seed" "$seed_port")
    qemu-system-x86_64 \
        -name "$name" -machine q35,accel=kvm -cpu host -smp "$CPUS" -m "$MEM" \
        -drive "file=$d/disk.qcow2,if=virtio,cache=writeback" \
        -device virtio-rng-pci \
        -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22,hostfwd=tcp:127.0.0.1:$HTTP_PORT-:80,hostfwd=tcp:127.0.0.1:$HTTPS_PORT-:443" \
        -smbios "type=1,serial=ds=nocloud-net;s=http://10.0.2.2:$seed_port/" \
        -display none -serial "file:$d/serial.log" \
        -daemonize -pidfile "$d/qemu.pid"
    log "booting $name, waiting for SSH on localhost:$SSH_PORT ..."
    local i
    for i in $(seq 1 90); do
        if ssh -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p "$SSH_PORT" \
            "$GUEST_USER@127.0.0.1" true 2>/dev/null; then
            kill "$seed_pid" 2>/dev/null || true
            log "$name is up after ~$((i * 2)) s: lab/vm.sh ssh $name"
            return 0
        fi
        sleep 2
    done
    kill "$seed_pid" 2>/dev/null || true
    die "SSH did not come up in 180 s; see $d/serial.log"
}

cmd_stop() {
    local name="${1:?name required}"
    load_env "$name"
    is_running "$name" || { log "$name is not running"; return 0; }
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -p "$SSH_PORT" "$GUEST_USER@127.0.0.1" 'sudo poweroff' 2>/dev/null || true
    local pid i; pid=$(cat "$(vm_dir "$name")/qemu.pid")
    for i in $(seq 1 30); do
        kill -0 "$pid" 2>/dev/null || { log "$name stopped"; return 0; }
        sleep 1
    done
    log "graceful shutdown timed out, killing"
    kill "$pid" 2>/dev/null || true
}

cmd_ssh() {
    local name="${1:?name required}"; shift || true
    load_env "$name"
    is_running "$name" || die "$name is not running"
    exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -p "$SSH_PORT" "$GUEST_USER@127.0.0.1" "$@"
}

cmd_snapshot() {
    local name="${1:?name required}" tag="${2:?tag required}"
    need_vm "$name"; ! is_running "$name" || die "stop $name first"
    qemu-img snapshot -c "$tag" "$(vm_dir "$name")/disk.qcow2"
    log "snapshot '$tag' of $name created"
}

cmd_restore() {
    local name="${1:?name required}" tag="${2:?tag required}"
    need_vm "$name"; ! is_running "$name" || die "stop $name first"
    qemu-img snapshot -a "$tag" "$(vm_dir "$name")/disk.qcow2"
    log "$name restored to '$tag'"
}

cmd_destroy() {
    local name="${1:?name required}"
    need_vm "$name"
    if is_running "$name"; then kill "$(cat "$(vm_dir "$name")/qemu.pid")" 2>/dev/null || true; sleep 1; fi
    rm -rf "$(vm_dir "$name")"
    log "$name destroyed"
}

cmd_list() {
    local d n
    for d in "$LAB"/vms/*/; do
        [ -d "$d" ] || continue
        n=$(basename "$d")
        # shellcheck disable=SC1091
        (. "$d/env"; printf '%-16s %-8s ssh:%s http:%s https:%s\n' "$n" \
            "$(is_running "$n" && echo running || echo stopped)" "$SSH_PORT" "$HTTP_PORT" "$HTTPS_PORT")
    done
}

cmd_console() { tail -n "${LINES_TO_SHOW:-50}" "$(vm_dir "${1:?name required}")/serial.log"; }

case "${1:-}" in
    create)   shift; cmd_create "$@" ;;
    start)    shift; cmd_start "$@" ;;
    stop)     shift; cmd_stop "$@" ;;
    ssh)      shift; cmd_ssh "$@" ;;
    snapshot) shift; cmd_snapshot "$@" ;;
    restore)  shift; cmd_restore "$@" ;;
    destroy)  shift; cmd_destroy "$@" ;;
    list)     cmd_list ;;
    console)  shift; cmd_console "$@" ;;
    *) sed -n '2,/^# ====/p' "$0" | sed 's/^# \{0,1\}//' | head -32; exit 1 ;;
esac
