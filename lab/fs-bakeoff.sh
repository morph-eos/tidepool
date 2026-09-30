#!/usr/bin/env bash
# =============================================================================
# lab/fs-bakeoff.sh — ext4 (as in v0), btrfs and ZFS under the same four tests. Runs INSIDE a lab VM, as root.
#
# Disks (by serial, see lab/vm.sh create --extra-disk): TPXTRA0001 ext4, TPXTRA0002 btrfs, TPXTRA0003 ZFS, TPXTRA0004 spare.
# Replication targets are sparse files on the data disk mounted at /mnt/nas, attached as loop devices.
#
#   F1  a block of a file is silently corrupted on the disk (single disk, no redundancy): is it noticed?
#   F2  the same, with redundancy (btrfs data=dup, ZFS copies=2): is it repaired?
#   F3  snapshot cost on 20,000 small files, and the space a snapshot takes after 1% of the files change
#   F4  incremental replication of that change to a second filesystem: time and bytes (ext4: rsync)
#   F5  memory used (ZFS ARC) after the workload
#
# Usage (inside the VM):  sudo bash fs-bakeoff.sh [ext4|btrfs|zfs ...]
# =============================================================================
set -uo pipefail

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
D=/dev/disk/by-id/virtio
WORK=/mnt/nas/fs-bakeoff
NFILES=${NFILES:-20000}
mkdir -p "$WORK"
declare -A R
now() { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$(now)" 'BEGIN{printf "%.2f", b-a}'; }
note() { printf '  %-6s %-4s %s\n' "$1" "$2" "$3"; R["$1/$2"]="$3"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

cleanup_fs() {
    umount -R /mnt/t-ext4 /mnt/t-btrfs /mnt/t-btrfs-dst 2>/dev/null || true
    zpool destroy -f tp 2>/dev/null; zpool destroy -f tpdst 2>/dev/null
    for l in $(losetup -j "$WORK/dst.img" -O NAME -n 2>/dev/null); do losetup -d "$l" 2>/dev/null; done
    wipefs -a "$D-TPXTRA0001" "$D-TPXTRA0002" "$D-TPXTRA0003" >/dev/null 2>&1 || true
    rm -f "$WORK"/dst.img
}

# Overwrite 4 KiB of a file's data directly on the raw device, bypassing the filesystem.
# The file starts with a repeated marker, so its first data block is found by searching the device.
corrupt_raw() { # corrupt_raw <device> <marker>
    local off
    off=$(grep -abo -m1 "$2" "$1" | head -1 | cut -d: -f1)
    [ -n "$off" ] || { echo "marker not found on $1" >&2; return 1; }
    dd if=/dev/urandom of="$1" bs=1 seek="$off" count=4096 conv=notrunc status=none
    echo "$off"
}
make_file() { # make_file <path> <marker>: 64 MiB, first block is a marker, the rest random
    { yes "$2" | head -c 4096; head -c $((64*1024*1024 - 4096)) /dev/urandom; } > "$1"
}

many_files() { # many_files <dir>: NFILES x 1 KiB
    mkdir -p "$1"
    local i
    for i in $(seq 1 "$NFILES"); do head -c 1024 /dev/urandom > "$1/f$i"; done
}
touch_percent() { # change 1% of the files
    local d="$1" i n=$((NFILES / 100))
    for i in $(seq 1 "$n"); do head -c 1024 /dev/urandom > "$d/f$((i * 97 % NFILES + 1))"; done
}

# ------------------------------------------------------------------- ext4
t_ext4() {
    local n=ext4 dev="$D-TPXTRA0001" m=/mnt/t-ext4 s
    mkdir -p $m; mkfs.ext4 -q -F "$dev"; mount "$dev" $m
    # F1
    make_file $m/big "MARK-EXT4-"; local want; want=$(sha $m/big); sync; umount $m
    corrupt_raw "$dev" "MARK-EXT4-" >/dev/null; mount "$dev" $m
    local got; got=$(sha $m/big 2>&1)
    if [ "$want" = "$got" ]; then note $n F1 "NOT DETECTED? file unchanged (corruption missed the file)"; else note $n F1 "SILENT: read succeeded with wrong content, no error anywhere"; fi
    note $n F2 "no redundancy option at this layer (would need RAID or LVM, still without checksums)"
    # F3/F4: no snapshots; "snapshot" = cp -al (hard links), replication = rsync
    many_files $m/data
    s=$(now); cp -al $m/data $m/snap1; note $n F3a "hard-link copy of $NFILES files: $(elapsed "$s") s (not a real snapshot: it does not keep the old content of a modified file)"
    touch_percent $m/data; sync
    mkdir -p "$WORK/ext4-dst"
    s=$(now); local out; out=$(rsync -a --stats $m/data/ "$WORK/ext4-dst/" 2>&1); note $n F4 "rsync first copy: $(elapsed "$s") s"
    touch_percent $m/data; sync
    s=$(now); out=$(rsync -a --stats $m/data/ "$WORK/ext4-dst/" 2>&1); note $n F4b "rsync incremental: $(elapsed "$s") s, $(echo "$out" | awk '/Total transferred file size/{print $5}') bytes sent (it has to walk all $NFILES files)"
    umount $m
}

# ------------------------------------------------------------------- btrfs
t_btrfs() {
    local n=btrfs dev="$D-TPXTRA0002" m=/mnt/t-btrfs s dst l
    mkdir -p $m /mnt/t-btrfs-dst
    mkfs.btrfs -q -f "$dev"; mount "$dev" $m
    # F1: single disk, default profile (data=single)
    make_file $m/big "MARK-BTRFS-"; local want; want=$(sha $m/big); sync; umount $m
    corrupt_raw "$dev" "MARK-BTRFS-" >/dev/null; mount "$dev" $m
    local got; got=$(sha $m/big 2>&1)
    if echo "$got" | grep -qiE 'input/output|error'; then note $n F1 "DETECTED: read failed with an I/O error (checksum mismatch), wrong data never returned"
    elif [ "$want" != "$got" ]; then note $n F1 "SILENT: wrong content returned"; else note $n F1 "file unchanged"; fi
    local sc; sc=$(btrfs scrub start -B $m 2>&1 | grep -iE 'error|uncorrectable|csum' | tr '\n' ' ')
    note $n F1s "scrub says: ${sc:-nothing found}"
    umount $m
    # F2: redundancy on a single disk: data=dup
    mkfs.btrfs -q -f -d dup -m dup "$dev"; mount "$dev" $m
    make_file $m/big "MARK-BTRFSD-"; want=$(sha $m/big); sync; umount $m
    corrupt_raw "$dev" "MARK-BTRFSD-" >/dev/null; mount "$dev" $m
    got=$(sha $m/big 2>&1)
    sc=$(btrfs scrub start -B $m 2>&1 | grep -iE 'corrected|error|uncorrectable' | tr '\n' ' ')
    if [ "$want" = "$got" ]; then note $n F2 "REPAIRED on read from the second copy; scrub: ${sc:-ok}"; else note $n F2 "not repaired"; fi
    umount $m
    # F3/F4: snapshots and send/receive
    mkfs.btrfs -q -f "$dev"; mount "$dev" $m
    truncate -s 4G "$WORK/dst.img"; dst=$(losetup -f --show "$WORK/dst.img"); mkfs.btrfs -q -f "$dst"; mount "$dst" /mnt/t-btrfs-dst
    btrfs subvolume create $m/data >/dev/null
    many_files $m/data
    s=$(now); btrfs subvolume snapshot -r $m/data $m/snap1 >/dev/null; note $n F3a "snapshot of $NFILES files: $(elapsed "$s") s"
    touch_percent $m/data; sync
    s=$(now); btrfs send -q $m/snap1 | btrfs receive -q /mnt/t-btrfs-dst; note $n F4 "first send/receive: $(elapsed "$s") s"
    btrfs subvolume snapshot -r $m/data $m/snap2 >/dev/null; sync
    local bytes
    bytes=$(btrfs send -q -p $m/snap1 $m/snap2 | tee >(btrfs receive -q /mnt/t-btrfs-dst) | wc -c)
    note $n F4b "incremental send/receive: $bytes bytes sent (only what changed)"
    local cs; cs=$(cd /mnt/t-btrfs-dst/snap2 && find . -type f | sort | head -2000 | xargs sha256sum | sha256sum | cut -c1-12); local cs2; cs2=$(cd $m/snap2 && find . -type f | sort | head -2000 | xargs sha256sum | sha256sum | cut -c1-12)
    [ "$cs" = "$cs2" ] && note $n F4c "replica identical to the source (sampled checksums)" || note $n F4c "REPLICA DIFFERS"
    note $n F3b "space used by the two snapshots' differences: $(btrfs filesystem du -s --raw $m/snap2 2>/dev/null | awk 'NR==2{print $3" bytes exclusive"}')"
    umount /mnt/t-btrfs-dst; losetup -d "$dst"; umount $m
}

# ------------------------------------------------------------------- ZFS
t_zfs() {
    local n=zfs dev="$D-TPXTRA0003" s dst
    modprobe zfs
    # F1: single disk, default
    zpool create -f -o ashift=12 -m /mnt/t-zfs tp "$dev"; zfs set compression=off tp
    make_file /mnt/t-zfs/big "MARK-ZFS-"; local want; want=$(sha /mnt/t-zfs/big); sync; zpool export tp
    corrupt_raw "$dev" "MARK-ZFS-" >/dev/null; zpool import -d /dev/disk/by-id tp 2>/dev/null
    local got; got=$(sha /mnt/t-zfs/big 2>&1)
    if echo "$got" | grep -qiE 'input/output|error'; then note $n F1 "DETECTED: read failed with an I/O error (checksum mismatch), wrong data never returned"
    elif [ "$want" != "$got" ]; then note $n F1 "SILENT: wrong content returned"; else note $n F1 "file unchanged"; fi
    zpool scrub -w tp 2>/dev/null; note $n F1s "scrub says: $(zpool status tp | grep -iE 'errors:|repaired' | tr -s ' ' | tr '\n' ' ')"
    zpool destroy -f tp
    # F2: copies=2
    zpool create -f -o ashift=12 -m /mnt/t-zfs tp "$dev"; zfs set compression=off copies=2 tp
    make_file /mnt/t-zfs/big "MARK-ZFSD-"; want=$(sha /mnt/t-zfs/big); sync; zpool export tp
    corrupt_raw "$dev" "MARK-ZFSD-" >/dev/null; zpool import -d /dev/disk/by-id tp 2>/dev/null
    got=$(sha /mnt/t-zfs/big 2>&1)
    zpool scrub -w tp 2>/dev/null
    if [ "$want" = "$got" ]; then note $n F2 "REPAIRED on read from the second copy; scrub: $(zpool status tp | grep -iE 'repaired' | tr -s ' ')"; else note $n F2 "not repaired"; fi
    zpool destroy -f tp
    # F3/F4
    zpool create -f -o ashift=12 -m /mnt/t-zfs tp "$dev"; zfs set compression=lz4 tp
    truncate -s 4G "$WORK/dst.img"; dst=$(losetup -f --show "$WORK/dst.img"); zpool create -f -o ashift=12 -m /mnt/t-zfs-dst tpdst "$dst"
    zfs create tp/data
    many_files /mnt/t-zfs/data
    s=$(now); zfs snapshot tp/data@snap1; note $n F3a "snapshot of $NFILES files: $(elapsed "$s") s"
    touch_percent /mnt/t-zfs/data; sync
    s=$(now); zfs send tp/data@snap1 | zfs receive -F tpdst/data; note $n F4 "first send/receive: $(elapsed "$s") s"
    zfs snapshot tp/data@snap2; sync
    local bytes; bytes=$(zfs send -i @snap1 tp/data@snap2 | tee >(zfs receive tpdst/data) | wc -c)
    note $n F4b "incremental send/receive: $bytes bytes sent (only what changed)"
    local cs cs2
    cs=$(cd /mnt/t-zfs-dst/data && find . -type f | sort | head -2000 | xargs sha256sum | sha256sum | cut -c1-12)
    cs2=$(cd /mnt/t-zfs/data && find . -type f | sort | head -2000 | xargs sha256sum | sha256sum | cut -c1-12)
    [ "$cs" = "$cs2" ] && note $n F4c "replica identical to the source (sampled checksums)" || note $n F4c "REPLICA DIFFERS"
    note $n F3b "space held by snap1 (the old content of the changed files): $(zfs list -H -p -o used -t snapshot tp/data@snap1) bytes"
    note $n F5 "ARC memory now: $(awk '/^size /{printf "%.0f MiB", $3/1048576}' /proc/spl/kstat/zfs/arcstats) (ARC is capped at about half of RAM by default, and gives it back under pressure); compression ratio $(zfs get -H -o value compressratio tp)"
    zpool destroy -f tpdst; zpool destroy -f tp; losetup -d "$dst"
}

want=("$@"); [ ${#want[@]} -gt 0 ] || want=(ext4 btrfs zfs)
cleanup_fs
for f in "${want[@]}"; do echo "== $f"; "t_$f"; cleanup_fs; done
echo; echo "== done"
