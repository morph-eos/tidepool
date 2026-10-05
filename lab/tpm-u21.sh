#!/usr/bin/env bash
# =============================================================================
# lab/tpm-u21.sh — ADR 0005 (2026-10-05): the encrypted layout of the real machine, tried in a VM with UEFI + Secure Boot firmware (OVMF) and an emulated TPM 2.0 (swtpm):
#   LUKS under the system root, under the ZFS pool and on the 2 TB disk; lanzaboote with the owner's own keys; the TPM sealed to PCR 7; a kernel update; and what a thief gets.
# Runs on the WORKSTATION; each stage waits for the previous one (the passphrase prompt of the initrd is answered through the serial console only while the TPM is not enrolled).
# Needs lab/tools/swtpm.sh (swtpm from the Ubuntu packages, no root) and the NixOS installer ISO (lab/nixos-install.sh). Takes about 25 minutes, most of it the installation.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; LAB="${TIDEPOOL_LAB:-$HOME/lab/tidepool}"; VM="$HERE/vm.sh"; D="$LAB/vms/host-s"; PP='lab-recovery-passphrase'
say() { echo "$(date +%H:%M:%S) $*"; }
S() { "$VM" ssh host-s "$@"; }
unlock() { "$HERE/serial-expect.py" "$D/serial.sock" 'login: $' --send "Please enter passphrase=$PP" --timeout 300 | grep -E "answered|final"; }   # types the recovery passphrase while the TPM is not enrolled
say "== 1. a UEFI VM with an emulated TPM, installed from the flake with LUKS on three disks (the passphrase becomes the recovery key)"
"$VM" create host-s --uefi --tpm --blank --disk 30 --data-disk 10 --extra-disk 6 --extra-disk 6 --mem 6144 --cpus 3
TIDEPOOL_NO_WAIT=1 TIDEPOOL_HOST=lab-secure TIDEPOOL_LAYOUT=disko TIDEPOOL_DISK_PASSPHRASE="$PP" TIDEPOOL_ENCRYPT_BIG2TB=1 "$HERE/nixos-install.sh" host-s
sleep 15; python3 - "$D/serial.sock" "$PP" <<'P'
import socket,sys,time
s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); time.sleep(.5); s.send((sys.argv[2]+"\n").encode())
P
unlock; sleep 20
say "layout: $(S 'lsblk -rno NAME,TYPE,FSTYPE | grep -E "crypt|zfs" | tr "\n" ";"')"; say "$(S 'sudo bootctl status 2>&1 | grep -E "Secure Boot|TPM2 Support" | tr -s " " | tr "\n" ";"')"
say "== 2. the signing keys, lanzaboote, the firmware (in setup mode) enrolls them by itself on the next boot"
(cd "$HERE/../nixos" && tar cf - --exclude=flake.lock .) | S 'rm -rf ~/nixos; mkdir ~/nixos && cd ~/nixos && tar xf -'
S 'export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH NIX_CONFIG="experimental-features = nix-command flakes"; sudo sbctl create-keys && sed -i "s/tidepool.encryption.enable = true;/tidepool.encryption = { enable = true; secureBoot = true; };/" ~/nixos/hosts/lab-secure/default.nix && sudo -E env PATH=$PATH nixos-rebuild switch --flake path:$HOME/nixos#lab-secure 2>&1 | tail -n 2'
S 'sudo systemctl reboot'; sleep 3; unlock; sleep 25
say "after the reboot: $(S 'sudo bootctl status 2>&1 | grep -E "Secure Boot" | tr -s " "; sudo sbctl status | grep -E "Vendor Keys" | tr -s " "')"
say "== 3. the TPM: each LUKS volume is sealed to PCR 7 (the Secure Boot state and the key that signs the boot image); the passphrase stays in slot 0"
S 'sudo sh -c "printf %s '"$PP"' > /root/pp; chmod 600 /root/pp"; for dev in /dev/disk/by-partlabel/disk-system-root /dev/disk/by-partlabel/disk-tank-zfs /dev/disk/by-id/virtio-TPXTRA0002; do sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 --unlock-key-file=/root/pp $dev 2>&1 | tail -n 1; done; sudo shred -u /root/pp'
L=$(wc -c < "$D/serial.log"); S 'sudo systemctl reboot'; sleep 3; "$HERE/serial-expect.py" "$D/serial.sock" 'login: $|Please enter passphrase' --timeout 300 | grep -E "final|answered"
say "boots by itself (no passphrase prompt): $([ "$(tail -c +$((L+1)) "$D/serial.log" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -c 'Please enter passphrase')" = 0 ] && echo yes || echo NO)"
say "== 4. a kernel update (6.18 to 6.12): the machine reboots and the disks open by themselves"
S 'export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH NIX_CONFIG="experimental-features = nix-command flakes"; printf "{ pkgs, ... }: { boot.kernelPackages = pkgs.linuxPackages_6_12; }\n" > ~/nixos/hosts/lab-secure/kernel.nix; sed -i "s|imports = \[ ../lab \];|imports = [ ../lab ./kernel.nix ];|" ~/nixos/hosts/lab-secure/default.nix; sudo -E env PATH=$PATH nixos-rebuild switch --flake path:$HOME/nixos#lab-secure 2>&1 | tail -n 1'
L=$(wc -c < "$D/serial.log"); S 'sudo systemctl reboot'; sleep 3; "$HERE/serial-expect.py" "$D/serial.sock" 'login: $|Please enter passphrase' --timeout 300 | grep -E "final|answered"; sleep 20
say "kernel $(S uname -r), prompts $(tail -c +$((L+1)) "$D/serial.log" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -c 'Please enter passphrase'), PCR 7 $(S 'sudo systemd-analyze pcrs 7 | tail -n 1 | tr -s " " | cut -c1-40')"
say "== 5. what a thief gets: (a) the disks in another machine (another TPM), (b) another system started on this machine (the installer)"
S 'sudo systemctl poweroff' >/dev/null 2>&1; sleep 15
mv "$D/tpm" "$D/tpm.keep"; mkdir "$D/tpm"; TIDEPOOL_NO_WAIT=1 "$VM" start host-s >/dev/null; "$HERE/serial-expect.py" "$D/serial.sock" 'login: $|Please enter passphrase' --timeout 120 | grep -E "final|Please enter" | head -n 2
say "(a) with another TPM the console asks for the passphrase: the disks stay closed"
kill "$(cat "$D/qemu.pid")"; sleep 2; kill "$(cat "$D/tpm/swtpm.pid")" 2>/dev/null; rm -rf "$D/tpm"; mv "$D/tpm.keep" "$D/tpm"
say "(b) the installer on this machine (the firmware reset to setup mode): done by hand in the session of 2026-10-05 — PCR 7 became 65caf8dd... instead of ab98654a..., and systemd-cryptsetup said"
say "    'TPM policy does not match current system state ... Operation not permitted': the key was not released and the disk did not open"
