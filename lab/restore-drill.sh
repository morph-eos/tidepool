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
HERE="$(cd "$(dirname "$0")" && pwd)"; VM="$HERE/vm.sh"; LAB="${TIDEPOOL_LAB:-$HOME/lab/tidepool}"; VMNAME="${DRILL_VM:-host-t}"; VMDIR="$LAB/vms/$VMNAME"; HOSTATTR="${DRILL_HOST:-lab}"; SECURE="${DRILL_SECURE:-0}"; PP='lab-recovery-passphrase'   # DRILL_SECURE=1: the encrypted layout (host lab-secure-sb on a UEFI VM with a TPM)
OUT="${DRILL_OUT:-/tmp/drill}"; mkdir -p "$OUT"
G() { "$VM" ssh "$VMNAME" "$@"; }
GS() { G "sudo bash /tmp/drill-guest.sh $1"; }
push() {
    "$HERE/vm.sh" ssh "$VMNAME" 'rm -rf /tmp/imgs' ; tar -C "${DRILL_IMGS:-/tmp/drill-imgs}" -cf - . | G 'mkdir -p /tmp/imgs && tar -C /tmp/imgs -xf -'
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
# the encrypted rebuild: the firmware still holds the OLD Secure Boot keys, so the new boot images must be signed with the SAME keys: they come back from Borg before the installation.
# The firmware is reset to setup mode for the installer (the NixOS ISO is not signed with our keys: on a real machine, Secure Boot is switched off for it); the restored keys are enrolled again at the first boot.
secure_rebuild() {
    cp /usr/share/OVMF/OVMF_VARS_4M.fd "$VMDIR/OVMF_VARS.fd"
    BP=$(SOPS_AGE_KEY_FILE="$LAB/age-lab.key" "$LAB/tools/sops" decrypt --extract '["borg-passphrase"]' "$HERE/../nixos/secrets/lab.yaml")
    TIDEPOOL_NO_WAIT=1 TIDEPOOL_HOST=lab-secure-sb TIDEPOOL_LAYOUT=disko TIDEPOOL_DISK_PASSPHRASE="$PP" TIDEPOOL_RESTORE_SBCTL_BORG_PASSPHRASE="$BP" "$HERE/nixos-install.sh" "$VMNAME" > "$OUT/install.log" 2>&1
    rc=$?; grep -E "restoring|archive |keys restored|NO KEYS|installer up|Out of memory|rror" "$OUT/install.log" | grep -v "warning: unable" | tail -n 6
    [ $rc -eq 0 ] && grep -q "installer up in" "$OUT/install.log" || { echo "THE INSTALLATION FAILED (exit $rc): see $OUT/install.log" >&2; return 1; }
    echo "== first boot (Secure Boot is still off: the firmware is in setup mode): the new root and pool ask for the passphrase, typed once; the firmware gets the restored keys at the NEXT boot"
    "$HERE/serial-expect.py" "$VMDIR/serial.sock" 'login: $' --send "Please enter passphrase=$PP" --timeout 400 | grep -E "answered|final"; sleep 25
    G 'sudo systemctl reboot' >/dev/null 2>&1; sleep 4
    echo "== second boot: the keys are enrolled (the passphrase again: the TPM does not know the new volumes yet)"
    "$HERE/serial-expect.py" "$VMDIR/serial.sock" 'login: $' --send "Please enter passphrase=$PP" --timeout 400 | grep -E "answered|final"; sleep 25
    echo "Secure Boot: $(G 'sudo bootctl status 2>&1 | grep -m1 "Secure Boot" | tr -s " "'); PCR 7: $(G 'sudo systemd-analyze pcrs 7 | tail -n 1 | tr -s " " | cut -c1-44') (the same value as before the disaster means the restored keys give the same boot state, so the 2 TB disk's old TPM seal still opens it)"
    echo "== the TPM for the new volumes (PCR 7), then a reboot that must need no passphrase"
    G 'sudo sh -c "printf %s '"$PP"' > /root/pp; chmod 600 /root/pp"; for dev in /dev/disk/by-partlabel/disk-system-root /dev/disk/by-partlabel/disk-tank-zfs; do sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 --unlock-key-file=/root/pp $dev 2>&1 | tail -n 1; done; sudo shred -u /root/pp'
    L=$(wc -c < "$VMDIR/serial.log"); G 'sudo systemctl reboot' >/dev/null 2>&1; sleep 3
    "$HERE/serial-expect.py" "$VMDIR/serial.sock" 'login: $|Please enter passphrase' --timeout 300 | grep -E "final|answered"; sleep 25
    echo "passphrase prompts after the enrollment: $(tail -c +$((L+1)) "$VMDIR/serial.log" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -c 'Please enter passphrase')"
}
stage_disaster() {
    t0=$(stamp); echo "== disaster: the system disk and the SSD are replaced by blank ones"
    "$VM" stop "$VMNAME"; sleep 2
    qemu-img create -q -f qcow2 "$VMDIR/disk.qcow2" "${DRILL_DISK_GB:-40}G"; qemu-img create -q -f qcow2 "$VMDIR/data.qcow2" "${DRILL_DATA_GB:-20}G"
    echo "== rebuild from the flake onto the blank machine"
    if [ "$SECURE" = 1 ]; then secure_rebuild || exit 1; else TIDEPOOL_HOST=lab TIDEPOOL_LAYOUT=disko "$HERE/nixos-install.sh" "$VMNAME" 2>&1 | tail -n 3; fi
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
