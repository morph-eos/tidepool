#!/usr/bin/env bash
# =============================================================================
# lab/restore-drill.sh <seed|disaster|restore|all> — the rebuild-from-scratch and restore drill (ADR 0014), driven from the workstation against the lab host "host-t".
#   seed      fill the services with data, take the backups, write down the moment T_GOOD, then do damage after it
#   disaster  stop the VM and replace the system disk and the SSD with blank ones (the two large backup disks survive), then reinstall the whole host from the flake
#   restore   on the rebuilt machine: files from Borg, the database to T_GOOD from pgBackRest, start everything, check it
# Create the VM once: lab/vm.sh create host-t --blank --cpus 4 --mem 8192 --disk 40 --data-disk 20 --extra-disk 30 --extra-disk 15
# and install it: TIDEPOOL_HOST=lab TIDEPOOL_LAYOUT=disko lab/nixos-install.sh host-t
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; VM="$HERE/vm.sh"; LAB="${TIDEPOOL_LAB:-$HOME/lab/tidepool}"; VMDIR="$LAB/vms/host-t"
OUT="${DRILL_OUT:-/tmp/drill}"; mkdir -p "$OUT"
G() { "$VM" ssh host-t "$@"; }
GS() { G "sudo bash /tmp/drill-guest.sh $1"; }
push() {
    "$HERE/vm.sh" ssh host-t 'rm -rf /tmp/imgs' ; tar -C "${DRILL_IMGS:-/tmp/drill-imgs}" -cf - . | G 'mkdir -p /tmp/imgs && tar -C /tmp/imgs -xf -'
    cat "$HERE/drill-guest.sh" | G 'cat > /tmp/drill-guest.sh'; cat "$HERE/immich-seed.sh" | G 'cat > /tmp/immich-seed.sh'
}
stamp() { date +%s; }
stage_seed() {
    push; echo "== waiting for the services"; GS wait
    echo "== seed: first data and the first backups"; GS seed1
    echo "== seed: more data, T_GOOD, the second backups"; GS seed2
    echo "== damage after T_GOOD"; GS damage
    G 'sudo cat /root/drill-state.env' > "$OUT/state.env"; G 'sudo cat /root/drill-immich-ids.txt' > "$OUT/immich-ids.txt"
    echo "state saved in $OUT"
}
stage_disaster() {
    t0=$(stamp); echo "== disaster: the system disk and the SSD are replaced by blank ones"
    "$VM" stop host-t; sleep 2
    qemu-img create -q -f qcow2 "$VMDIR/disk.qcow2" 40G; qemu-img create -q -f qcow2 "$VMDIR/data.qcow2" 20G
    echo "== rebuild from the flake onto the blank machine"
    TIDEPOOL_HOST=lab TIDEPOOL_LAYOUT=disko "$HERE/nixos-install.sh" host-t 2>&1 | tail -n 3
    echo "rebuild took $(( $(stamp) - t0 )) s from the disaster to a booted system" | tee "$OUT/rebuild-time.txt"
}
stage_restore() {
    t0=$(stamp); push
    cat "$OUT/state.env" | G 'sudo tee /root/drill-state.env >/dev/null'; cat "$OUT/immich-ids.txt" | G 'sudo tee /root/drill-immich-ids.txt >/dev/null'
    echo "== the rebuilt machine, empty"; GS wait
    echo "== restore"; GS stop-services; GS restore-files; GS restore-db; GS restore-incus; GS start-services
    echo "== verify"; GS verify | tee "$OUT/verify.txt"
    echo "restore took $(( $(stamp) - t0 )) s (from the first command on the rebuilt machine to the end of the checks)" | tee "$OUT/restore-time.txt"
}
case "${1:?stage}" in
seed) stage_seed ;; disaster) stage_disaster ;; restore) stage_restore ;;
all) stage_seed; stage_disaster; stage_restore ;;
esac
