#!/usr/bin/env bash
# =============================================================================
# lab/experiments/vms-engines-run.sh — drives R2 (ADR 0013) from the workstation: for each variant, boots host-v into that specialisation, starts the Incus instances, runs lab/experiments/vms-engines-bakeoff.sh and collects the log.
# Usage: lab/experiments/vms-engines-run.sh [variant...]   (default: docker docker-declared podman podman-declared)
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; VM="$HERE/vm.sh"
V() { "$VM" ssh host-v "$@"; }
OUT=${OUT:-/tmp/engines}; mkdir -p "$OUT"
for variant in "${@:-docker docker-declared podman podman-declared}"; do for variant in $variant; do
    engine=${variant%%-*}
    V "sudo /nix/var/nix/profiles/system/specialisation/$variant/bin/switch-to-configuration boot >/dev/null 2>&1; sudo systemctl reboot" >/dev/null 2>&1
    sleep 30; for i in $(seq 1 40); do V true 2>/dev/null && break; sleep 6; done
    for i in $(seq 1 20); do [ "$(V 'sudo incus list -f csv -c s 2>/dev/null | grep -c RUNNING')" -ge 2 ] && break; sleep 5; done; sleep 10
    cat "$HERE/${SCRIPT:-vms-engines-bakeoff.sh}" | V 'cat > /tmp/eng.sh'
    V "sudo systemd-run --unit=eng-$variant --collect -E PATH=/run/wrappers/bin:/run/current-system/sw/bin --property=StandardOutput=file:/tmp/eng-$variant.log --property=StandardError=file:/tmp/eng-$variant.log bash /tmp/eng.sh ${ARG:-$engine}" >/dev/null 2>&1
    for i in $(seq 1 60); do V "systemctl is-active eng-$variant" 2>/dev/null | grep -q '^active' || break; sleep 10; done
    V "cat /tmp/eng-$variant.log" > "$OUT/$variant.log" 2>&1
    echo "== $variant done"
done; done
