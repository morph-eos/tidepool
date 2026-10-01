#!/usr/bin/env bash
# =============================================================================
# lab/mirror-bakeoff.sh — a two-disk mirror on btrfs RAID1 and on ZFS, plain and on LUKS: damage, a dead member, its replacement, and a PostgreSQL toy run.
# Runs INSIDE a NixOS lab VM, as root. Lab scaffolding, not part of the system. Disks by serial: TPXTRA0001/0002 are the mirror, TPXTRA0003 the spare.
#
#   M1  mirror created; 400 MB written (checksummed list)
#   M2  partial damage: 400 MB of one member overwritten with random bytes, then the filesystem's own scrub: how many errors, are they repaired, is the data identical
#   M3  the whole member is lost (zeroed); how does the system say so; the spare replaces it; time, number of commands; scrub clean and data identical afterwards
#   M4  PostgreSQL 17, pgbench 4 clients for 30 s on the mirror (a toy, on 6 GB virtual disks: it says whether something is wildly slow, not how fast the real disks are)
#
# Usage:  sudo bash mirror-bakeoff.sh [btrfs zfs btrfs-luks zfs-luks]
# =============================================================================
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH
D=/dev/disk/by-id/virtio
RAW0=$D-TPXTRA0001; RAW1=$D-TPXTRA0002; RAWS=$D-TPXTRA0003
MNT=/mnt/mir; KEY=/root/lab-luks.key
declare -A RES
say() { printf '  %s\n' "$*"; }
now() { date +%s.%N; }
el() { awk -v a="$1" -v b="$(now)" 'BEGIN{printf "%.1f", b-a}'; }
CMDS=0; run() { CMDS=$((CMDS + 1)); "$@"; }   # counts the commands a person would have to type for the procedure

teardown() {
    # nothing may still use the lab disks (earlier experiments mount them): a mount left behind made every command fail while the run carried on
    for pid in $(pgrep -x postgres); do kill -9 "$pid" 2>/dev/null; done; sleep 1
    umount -R $MNT 2>/dev/null; zpool destroy -f tank 2>/dev/null; umount /mnt/pgx /mnt/pgrepo 2>/dev/null
    for m in cm0 cm1 cms; do cryptsetup close $m 2>/dev/null; done
    for r in $RAW0 $RAW1 $RAWS; do wipefs -a "$r" >/dev/null 2>&1; dd if=/dev/zero of="$r" bs=1M count=16 status=none; done
    rm -rf $MNT; mkdir -p $MNT   # a mount point that an earlier failed run filled on the system disk would stop zpool create
    if lsblk -rno MOUNTPOINTS "$RAW0" "$RAW1" "$RAWS" | grep -q .; then echo "FATAL: a lab disk is still mounted"; exit 2; fi
}
members() { # members <luks?>: sets M0 M1 MS
    if [ "$1" = luks ]; then
        head -c 64 /dev/urandom > $KEY
        for pair in "cm0:$RAW0" "cm1:$RAW1" "cms:$RAWS"; do
            cryptsetup luksFormat --batch-mode --pbkdf pbkdf2 --iter-time 50 --key-file $KEY "${pair#*:}" >/dev/null 2>&1 || { echo "FATAL: luksFormat failed"; exit 2; }
            cryptsetup open --key-file $KEY "${pair#*:}" "${pair%%:*}" || { echo "FATAL: luks open failed"; exit 2; }
        done
        M0=/dev/mapper/cm0; M1=/dev/mapper/cm1; MS=/dev/mapper/cms
    else M0=$RAW0; M1=$RAW1; MS=$RAWS; fi
}
make_data() {
    mkdir -p $MNT/data
    for i in $(seq 1 100); do head -c 4194304 /dev/urandom > $MNT/data/f$i.bin; done
    for i in $(seq 1 500); do seq 1 $((i % 50 + 5)) > $MNT/data/s$i.txt; done
    (cd $MNT && find data -type f | sort | xargs sha256sum > /root/sums.txt); sync
}
verify() { (cd $MNT && sha256sum -c --quiet /root/sums.txt 2>&1 | head -n 3); }
same() { local o; o=$(verify); [ -z "$o" ] && echo "all files identical" || echo "DIFFERENT: $o"; }

cand() { # cand <fs> <luks?>
    local fs=$1 lk=$2 name=$1; [ "$2" = luks ] && name=$1-luks
    echo "== $name"; teardown; members "$lk"
    local t0 out
    # ---------------------------------------------------------------- M1
    CMDS=0
    if [ "$fs" = btrfs ]; then run mkfs.btrfs -q -f -d raid1 -m raid1 $M0 $M1 && run mount $M0 $MNT
    else run zpool create -f -o ashift=12 -O mountpoint=$MNT -O compression=lz4 tank mirror $M0 $M1; fi || { say "$name: the mirror was NOT created, stopping this candidate"; return; }
    findmnt -n $MNT >/dev/null || { say "$name: $MNT is not a mount, stopping this candidate"; return; }
    make_data
    say "$name M1: mirror created ($CMDS commands), 400 MB written"
    # ---------------------------------------------------------------- M2
    dd if=/dev/urandom of=$M1 bs=1M seek=16 count=400 conv=notrunc status=none; sync
    t0=$(now)
    if [ "$fs" = btrfs ]; then out=$(btrfs scrub start -B $MNT 2>&1 | grep -E "corrected|Error summary|uncorrectable" | tr '\n' ' ')
    else zpool scrub -w tank; out=$(zpool status tank | grep -E "scrub repaired|errors:" | tr '\n' ' '); fi
    say "$name M2: partial damage, scrub in $(el "$t0")s: ${out:-no scrub output}; $(same)"
    RES[$name/M2]="$(same)"
    # a second scrub must be clean
    if [ "$fs" = btrfs ]; then out=$(btrfs scrub start -B $MNT 2>&1 | grep -E "Error summary" | tr '\n' ' '); else zpool scrub -w tank; out=$(zpool status tank | grep -E "errors:" | tr '\n' ' '); fi
    say "$name M2b: second scrub: $out"
    # ---------------------------------------------------------------- M3
    dd if=/dev/zero of=$M1 bs=1M status=none 2>/dev/null; sync
    echo 3 > /proc/sys/vm/drop_caches
    local notice
    if [ "$fs" = btrfs ]; then
        verify >/dev/null; notice="$(btrfs device stats $MNT 2>&1 | grep -vE ' 0$' | head -n 3 | tr '\n' ' ')"
    else
        verify >/dev/null; zpool scrub -w tank 2>/dev/null; notice="$(zpool status -x 2>&1 | head -n 2 | tr '\n' ' ') $(zpool status tank | grep -E 'DEGRADED|FAULTED|UNAVAIL|errors:' | head -n 3 | tr '\n' ' ')"
    fi
    say "$name M3: member lost; what the tool reports: ${notice:-NOTHING}"
    say "$name M3: data while degraded: $(same)"
    CMDS=0; t0=$(now)
    if [ "$fs" = btrfs ]; then
        run btrfs filesystem show $MNT >/dev/null
        run btrfs replace start -B -r 2 $MS $MNT
        run btrfs scrub start -B $MNT >/tmp/m3scrub.log 2>&1
    else
        run zpool replace -w tank $M1 $MS
        run zpool scrub -w tank
    fi
    local rt; rt=$(el "$t0")
    if [ "$fs" = btrfs ]; then out=$(grep -E "Error summary" /tmp/m3scrub.log | tr '\n' ' '); out="$out; devices: $(btrfs filesystem show $MNT | grep -c devid)"; else out=$(zpool status tank | grep -E "state:|errors:" | tr '\n' ' '); fi
    say "$name M3: replaced in ${rt}s with $CMDS commands; afterwards: $out; $(same)"
    RES[$name/M3]="${rt}s, $CMDS commands, $(same)"
    # ---------------------------------------------------------------- M4
    mkdir -p $MNT/pg; chown postgres:postgres $MNT/pg
    sudo -u postgres initdb -D $MNT/pg/data --data-checksums >/dev/null 2>&1
    sudo -u postgres pg_ctl -D $MNT/pg/data -o "-p 5600 -k /tmp -c listen_addresses=''" -w -l $MNT/pg/log start >/dev/null 2>&1
    sudo -u postgres createdb -h /tmp -p 5600 bench; sudo -u postgres pgbench -h /tmp -p 5600 -i -s 10 -q bench >/dev/null 2>&1
    out=$(sudo -u postgres pgbench -h /tmp -p 5600 -c 4 -j 2 -T 30 bench 2>&1 | grep -E "^tps" | head -n 1)
    sudo -u postgres pg_ctl -D $MNT/pg/data -m fast -w stop >/dev/null 2>&1
    say "$name M4: pgbench 30 s: $out"; RES[$name/M4]="$out"
}

want=("$@"); [ ${#want[@]} -gt 0 ] || want=(btrfs zfs btrfs-luks zfs-luks)
for c in "${want[@]}"; do
    case $c in btrfs) cand btrfs plain;; zfs) cand zfs plain;; btrfs-luks) cand btrfs luks;; zfs-luks) cand zfs luks;; esac
done
teardown
echo; echo "== summary"
for k in $(printf '%s\n' "${!RES[@]}" | sort); do printf '  %-16s %s\n' "$k" "${RES[$k]}"; done
