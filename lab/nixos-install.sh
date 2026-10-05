#!/usr/bin/env bash
# =============================================================================
# lab/nixos-install.sh — install NixOS from the flake in nixos/ into an empty lab VM
#
# Usage:
#   lab/vm.sh create host-n --blank --disk 40 --data-disk 20
#   lab/nixos-install.sh host-n
#
# What it does: boots the official installer ISO with its kernel and initrd extracted (so the console is the
# serial line), starts sshd there through the serial console, copies the flake and the age key, partitions the
# disk, runs nixos-install, and reboots into the installed system. Needs no root and no screen.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LAB="${TIDEPOOL_LAB:-$HOME/lab/tidepool}"
NAME="${1:?usage: nixos-install.sh <vm-name>}"
ISO="${TIDEPOOL_NIXOS_ISO:-$LAB/base/nixos-26.05-minimal.iso}"
AGE_KEY="${TIDEPOOL_AGE_KEY:-$LAB/age-lab.key}"
PUBKEY="${TIDEPOOL_SSH_KEY:-$HOME/.ssh/id_ed25519.pub}"
PY="${TIDEPOOL_PY:-$LAB/pyenv/bin/python}"
VMDIR="$LAB/vms/$NAME"
HOST_ATTR="${TIDEPOOL_HOST:-tidepool-lab}"          # the flake output to install (the integrated lab host is "lab")
PASSPHRASE="${TIDEPOOL_DISK_PASSPHRASE:-}"      # set for an encrypted layout (tidepool.encryption.enable): the LUKS passphrase, which stays the recovery key
BORG_PP="${TIDEPOOL_RESTORE_SBCTL_BORG_PASSPHRASE:-}"   # set: before installing, take /var/lib/sbctl (the Secure Boot signing keys) from the newest archive of the Borg repository on the surviving 16 TB disk
ENC_BIG2TB="${TIDEPOOL_ENCRYPT_BIG2TB:-0}"        # 1: the 2 TB disk (TPXTRA0002) gets LUKS too
LAYOUT="${TIDEPOOL_LAYOUT:-parted}"               # parted: the old two-line layout; disko: the layout declared in the flake (modules/storage.nix)
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes)

log() { echo "[nixos-install] $*"; }
die() { echo "error: $*" >&2; exit 1; }
[ -d "$VMDIR" ] || die "no such VM: $NAME (create it with --blank)"
[ -f "$ISO" ] || die "installer ISO not found: $ISO"
[ -r "$AGE_KEY" ] || die "age key not found: $AGE_KEY"
# shellcheck disable=SC1091
. "$VMDIR/env"
[ "${BLANK:-0}" = 1 ] || die "$NAME is not a blank VM"

START=$(date +%s)
BOOT="$LAB/base/nixos-boot"
if [ ! -f "$BOOT/bzImage" ]; then
    mkdir -p "$BOOT"
    log "extracting kernel, initrd and command line from the ISO"
    "$PY" "$HERE/iso-boot-files.py" "$ISO" "$BOOT" > "$BOOT/cmdline"
fi

cat > "$VMDIR/extra-args" <<ARGS
-kernel
$BOOT/bzImage
-initrd
$BOOT/initrd
-append
$(cat "$BOOT/cmdline") console=ttyS0
-drive
file=$ISO,media=cdrom,readonly=on,if=none,id=cd0
-device
ide-cd,drive=cd0
ARGS

log "booting the installer"
TIDEPOOL_NO_WAIT=1 "$HERE/vm.sh" start "$NAME"
"$PY" "$HERE/serial-run.py" "$VMDIR/serial.sock" --timeout 300 \
    "mkdir -p ~/.ssh && echo '$(cut -d' ' -f1,2 "$PUBKEY")' > ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" \
    "sudo systemctl start sshd" >/dev/null

log "waiting for SSH on the installer"
for _ in $(seq 1 30); do
    ssh -n "${SSH_OPTS[@]}" -p "$SSH_PORT" nixos@127.0.0.1 true 2>/dev/null && break
    sleep 2
done
ssh -n "${SSH_OPTS[@]}" -p "$SSH_PORT" nixos@127.0.0.1 true || die "installer SSH did not come up"
T_BOOT=$(date +%s)

log "copying the flake and the age key"
tar -C "$REPO" -cf - nixos | ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" nixos@127.0.0.1 'tar -C ~ -xf -'
ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" nixos@127.0.0.1 'cat > ~/age.key' < "$AGE_KEY"

log "partitioning, formatting, installing (downloads the system: this is the long step)"
ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" nixos@127.0.0.1 "LAYOUT=$LAYOUT HOST_ATTR=$HOST_ATTR PASSPHRASE='$PASSPHRASE' ENC_BIG2TB=$ENC_BIG2TB BORG_PP='$BORG_PP' bash -s" <<'REMOTE'
set -euo pipefail
export NIX_CONFIG='experimental-features = nix-command flakes
download-attempts = 60
stalled-download-timeout = 60
connect-timeout = 15'   # the lab's link drops downloads now and then: a failed download otherwise ends in "dependency failed"
# Lock the inputs first, as the normal user: if nixos-install creates flake.lock itself (as root) the hash of the
# flake directory changes in the middle of the evaluation and it fails with "NAR hash mismatch".
nix flake lock path:$HOME/nixos
sudo umount -R /mnt 2>/dev/null || true
if [ "$LAYOUT" = disko ]; then
    # first-time provisioning of the two large backup disks: made only if they hold no filesystem, so a reinstall that keeps them (the restore drill) leaves them alone
    [ -n "$PASSPHRASE" ] && printf '%s' "$PASSPHRASE" | sudo tee /tmp/disk-passphrase >/dev/null
    for dev in /dev/disk/by-id/virtio-TPXTRA0001 /dev/disk/by-id/virtio-TPXTRA0002; do
        if [ -e "$dev" ] && ! sudo blkid "$dev" >/dev/null 2>&1; then
            if [ "$ENC_BIG2TB" = 1 ] && [ "$dev" = /dev/disk/by-id/virtio-TPXTRA0002 ]; then
                # the encrypted 2 TB disk: LUKS directly on the disk, a filesystem inside; opened once here to make it, closed again (the installed system opens it itself)
                printf '%s' "$PASSPHRASE" | sudo cryptsetup luksFormat --batch-mode --key-file=- "$dev"
                printf '%s' "$PASSPHRASE" | sudo cryptsetup open --key-file=- "$dev" big2tb-setup
                sudo mkfs.ext4 -q /dev/mapper/big2tb-setup && echo "formatted $dev (LUKS)"
                sudo mount /dev/mapper/big2tb-setup /mnt && sudo mkdir -p /mnt/incus-state && sudo umount /mnt && sudo cryptsetup close big2tb-setup
            else
                sudo mkfs.ext4 -q "$dev" && echo "formatted $dev" && sudo mount "$dev" /mnt && sudo mkdir -p /mnt/incus-state && sudo umount /mnt
            fi
        fi
    done
    # the layout comes from the flake: the system disk and the SSD's ZFS pool are wiped and made; the two large backup disks are not touched
    sudo -H -E nix run github:nix-community/disko -- --mode destroy,format,mount --yes-wipe-all-disks --flake path:$HOME/nixos#${HOST_ATTR}
else
    sudo parted -s /dev/vda -- mklabel msdos mkpart primary ext4 1MiB 100%
    sudo mkfs.ext4 -q -L nixos /dev/vda1
    sudo mount /dev/disk/by-label/nixos /mnt
fi
if [ -n "$BORG_PP" ]; then
    echo "restoring the signing keys from Borg"
    sudo mkdir -p /mnt-bk && sudo mount -o ro /dev/disk/by-id/virtio-TPXTRA0001 /mnt-bk
    sudo -H -E nix shell nixpkgs#borgbackup -c env BORG_PASSPHRASE="$BORG_PP" BORG_RELOCATED_REPO_ACCESS_IS_OK=yes sh -c 'cd /mnt && A=$(borg list --bypass-lock --last 1 --short /mnt-bk/borg-everything) && echo "archive $A" && borg extract --bypass-lock /mnt-bk/borg-everything::"$A" var/lib/sbctl'   # the repository's disk is mounted read-only (a reinstall must not touch a backup): --bypass-lock reads without writing the lock
    sudo umount /mnt-bk
    sudo test -f /mnt/var/lib/sbctl/keys/db/db.pem && echo "keys restored: $(sudo ls /mnt/var/lib/sbctl/keys | tr '\n' ' ')" || { echo "NO KEYS in the backup" >&2; exit 1; }
fi
sudo mkdir -p /mnt/var/lib/sops-nix
sudo install -m 600 ~/age.key /mnt/var/lib/sops-nix/key.txt
sudo -H -E nixos-install --flake path:$HOME/nixos#${HOST_ATTR} --no-root-passwd
REMOTE
T_INSTALL=$(date +%s)

log "keeping the flake.lock the installer produced, so the result can be reproduced"
ssh -n "${SSH_OPTS[@]}" -p "$SSH_PORT" nixos@127.0.0.1 'cat ~/nixos/flake.lock' > "$REPO/nixos/flake.lock" || true

log "rebooting into the installed system"
ssh -n "${SSH_OPTS[@]}" -p "$SSH_PORT" nixos@127.0.0.1 'sudo poweroff' 2>/dev/null || true
for _ in $(seq 1 30); do
    "$HERE/vm.sh" list | grep -q "^$NAME .*stopped" && break
    sleep 2
done
rm -f "$VMDIR/extra-args"
"$HERE/vm.sh" start "$NAME"
END=$(date +%s)
log "installer up in $((T_BOOT - START)) s, nixos-install $((T_INSTALL - T_BOOT)) s, total to a booted system $((END - START)) s"
