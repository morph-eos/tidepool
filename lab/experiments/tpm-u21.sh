#!/usr/bin/env bash
# =============================================================================
# lab/experiments/tpm-u21.sh — ADR 0005 (2026-10-05): the encrypted layout of the real machine, tried in a VM with UEFI + Secure Boot firmware (OVMF) and an emulated TPM 2.0 (swtpm):
#   LUKS under the system root, under the ZFS pool and on the 2 TB disk; lanzaboote with the owner's own keys; the TPM sealed to PCR 7; a kernel update; and what a thief gets.
# Runs on the WORKSTATION; each stage waits for the previous one (the passphrase prompt of the initrd is answered through the serial console only while the TPM is not enrolled).
# Needs lab/tools/swtpm.sh (swtpm from the Ubuntu packages, no root) and the NixOS installer ISO (lab/nixos-install.sh). Takes about 25 minutes, most of it the installation.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; LAB="${TIDEPOOL_LAB:-$HOME/lab/tidepool}"; VM="$HERE/vm.sh"; D="$LAB/vms/host-s"; PP='lab-recovery-passphrase'
say() { echo "$(date +%H:%M:%S) $*"; }
S() { "$VM" ssh host-s "$@" < /dev/null; }
fail() { say "FAIL: $*"; exit 1; }
# A check that does not hold stops the script: a probe that returns nothing (a VM that never came up) must not read as a pass.
check() { [ "$2" = "$3" ] && say "  ok   $1: $3" || fail "$1: expected [$2], got [$3]"; }
unlock() { "$HERE/serial-unlock.py" "$D/serial.sock" "$D/serial.log" "$PP" 300 "${1:-0}" || fail "no login prompt on the console (the passphrase prompts were not all answered)"; }   # while the TPM is not enrolled: the recovery passphrase, whatever the timing
wait_ssh() { local i; for i in $(seq 1 40); do S true 2>/dev/null && return 0; sleep 4; done; fail "the VM does not answer on SSH"; }
prompts() { tail -c +$(($1+1)) "$D/serial.log" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -c 'Please enter passphrase'; }   # passphrase prompts on the console since byte offset $1
rebuild() {   # nixos-rebuild switch of lab-secure inside the VM; its exit status is checked
  local out; out=$(S 'export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH NIX_CONFIG="experimental-features = nix-command flakes
download-attempts = 60"; sudo -E env PATH=$PATH nixos-rebuild switch --flake path:$HOME/nixos#lab-secure > /tmp/rebuild.log 2>&1; echo "exit $?"; tail -n 2 /tmp/rebuild.log')
  say "rebuild: $(echo "$out" | tr '\n' ' ' | cut -c1-200)"; echo "$out" | head -n 1 | grep -q '^exit 0$' || fail "nixos-rebuild failed in the VM"
}
say "== 1. a UEFI VM with an emulated TPM, installed from the flake with LUKS on three disks (the passphrase becomes the recovery key)"
"$VM" destroy host-s >/dev/null 2>&1 || true   # a VM of an earlier run
"$VM" create host-s --uefi --tpm --blank --disk 30 --data-disk 10 --extra-disk 6 --extra-disk 6 --mem 6144 --cpus 3
TIDEPOOL_NO_WAIT=1 TIDEPOOL_HOST=lab-secure TIDEPOOL_LAYOUT=disko TIDEPOOL_DISK_PASSPHRASE="$PP" TIDEPOOL_ENCRYPT_BIG2TB=1 "$HERE/nixos-install.sh" host-s
unlock 0; wait_ssh
check "three encrypted volumes" "3" "$(S 'lsblk -rno NAME,TYPE | grep -c crypt')"
say "== 2. the signing keys, lanzaboote, the firmware (in setup mode) enrolls them by itself on the next boot"
(cd "$HERE/../nixos" && tar cf - --exclude=flake.lock .) | "$VM" ssh host-s 'rm -rf ~/nixos; mkdir ~/nixos && cd ~/nixos && tar xf -'
S 'sudo sbctl create-keys >/dev/null 2>&1 && sed -i "s/tidepool.encryption.enable = true;/tidepool.encryption = { enable = true; secureBoot = true; };/" ~/nixos/hosts/lab-secure/default.nix' || fail "sbctl create-keys"
rebuild
L=$(wc -c < "$D/serial.log"); S 'sudo systemctl reboot' 2>/dev/null; sleep 3; unlock "$L"; wait_ssh
check "Secure Boot after the reboot" "Secure Boot: enabled (user)" "$(S 'sudo bootctl status 2>&1 | grep "Secure Boot" | tr -s " " | sed "s/^ //"')"
say "== 3. the TPM: each LUKS volume is sealed to PCR 7 (the Secure Boot state and the key that signs the boot image); the passphrase stays in slot 0"
S 'sudo sh -c "printf %s '"$PP"' > /root/pp; chmod 600 /root/pp"; for dev in /dev/disk/by-partlabel/disk-system-root /dev/disk/by-partlabel/disk-tank-zfs /dev/disk/by-id/virtio-TPXTRA0002; do sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 --unlock-key-file=/root/pp $dev 2>&1 | tail -n 1; done; sudo shred -u /root/pp'
check "a TPM token on each of the three volumes" "1 1 1 " "$(S 'for d in $(lsblk -rno NAME,FSTYPE | awk "\$2==\"crypto_LUKS\"{print \$1}"); do sudo cryptsetup luksDump /dev/$d 2>/dev/null | grep -c systemd-tpm2; done | tr "\n" " "')"
PCR3=$(S 'sudo systemd-analyze pcrs 7 | tail -n 1 | tr -s " "')
L=$(wc -c < "$D/serial.log"); S 'sudo systemctl reboot' 2>/dev/null; sleep 3; "$HERE/serial-expect.py" "$D/serial.sock" 'login: $|Please enter passphrase' --timeout 300 >/dev/null; wait_ssh
check "boots by itself: passphrase prompts" "0" "$(prompts "$L")"
say "== 4. a kernel update (6.18 to 6.12): the machine reboots and the disks open by themselves"
S 'printf "{ pkgs, ... }: { boot.kernelPackages = pkgs.linuxPackages_6_12; }\n" > ~/nixos/hosts/lab-secure/kernel.nix; sed -i "s|imports = \[ ../lab \];|imports = [ ../lab ./kernel.nix ];|" ~/nixos/hosts/lab-secure/default.nix' || fail "kernel.nix"
rebuild
L=$(wc -c < "$D/serial.log"); S 'sudo systemctl reboot' 2>/dev/null; sleep 3; "$HERE/serial-expect.py" "$D/serial.sock" 'login: $|Please enter passphrase' --timeout 300 >/dev/null; wait_ssh
check "the kernel changed" "6.12" "$(S uname -r | cut -c1-4)"
check "passphrase prompts after the kernel update" "0" "$(prompts "$L")"
check "PCR 7 is the same after the kernel update" "$PCR3" "$(S 'sudo systemd-analyze pcrs 7 | tail -n 1 | tr -s " "')"
say "== 5. what a thief gets: (a) the disks in another machine (another TPM), (b) another system started on this machine (the installer)"
S 'sudo systemctl poweroff' >/dev/null 2>&1; sleep 15
mv "$D/tpm" "$D/tpm.keep"; mkdir "$D/tpm"; TIDEPOOL_NO_WAIT=1 "$VM" start host-s >/dev/null; "$HERE/serial-expect.py" "$D/serial.sock" 'login: $|Please enter passphrase' --timeout 120 >/dev/null
P=$(prompts 0)
kill "$(cat "$D/qemu.pid")"; sleep 2; kill "$(cat "$D/tpm/swtpm.pid")" 2>/dev/null; rm -rf "$D/tpm"; mv "$D/tpm.keep" "$D/tpm"
[ "$P" -ge 1 ] && say "  ok   (a) with another TPM the console asks for the passphrase ($P prompt(s)): the disks stay closed" || fail "(a) another TPM did not get a passphrase prompt: the disks may have opened"
say "(b) the installer on this machine (the firmware reset to setup mode): done by hand in the session of 2026-10-05 — PCR 7 became 65caf8dd... instead of ab98654a..., and systemd-cryptsetup said"
say "    'TPM policy does not match current system state ... Operation not permitted': the key was not released and the disk did not open"
say "RESULT: PASS"
