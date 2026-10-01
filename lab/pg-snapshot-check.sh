#!/usr/bin/env bash
# =============================================================================
# lab/pg-snapshot-check.sh — is a snapshot taken WHILE PostgreSQL is writing a valid backup? (runs inside a lab VM, as root)
#
# Claim to test: a filesystem snapshot of the dataset that holds both the data and the WAL is crash-consistent, so PostgreSQL recovers from it
# with no loss beyond the moment of the snapshot. If true, frequent snapshots (sanoid, btrbk: native NixOS modules) give a short data-loss window
# for the databases without any PostgreSQL-specific backup tool or script (principle P1).
#
# For each filesystem: start a cluster on it, run pgbench (continuous writes), take N snapshots at random moments while it runs, then restore
# each snapshot to a new place, start PostgreSQL on it, and check the pgbench invariant (the sums of the balances of accounts, tellers and branches
# must be equal) and that a counter table has no gaps.
#
# Usage: sudo bash pg-snapshot-check.sh [zfs|btrfs ...]      N=5 snapshots by default
# =============================================================================
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
N=${N:-5}
# initdb, pg_ctl, psql and pgbench come from the native services.postgresql module, which puts the package in the system path
D=/dev/disk/by-id/virtio
ok=0; bad=0; CTRL_N=0; CTRL_BROKE=0
say() { printf '  %s\n' "$*"; }
pg() { sudo -u postgres "$@"; }

check_cluster() { # check_cluster <datadir> <port> <label>: start, verify invariants, stop. Prints a result line and updates the counters
    local dd=$1 port=$2 label=$3 t0 inv gaps
    t0=$(date +%s.%N)
    if ! pg pg_ctl -D "$dd" -o "-p $port -k /tmp -c listen_addresses=''" -w -t 60 -l "$dd/../pg-$label.log" start >/dev/null 2>&1; then
        say "$label: DID NOT START"; bad=$((bad + 1)); return
    fi
    local up; up=$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.1f", b-a}')
    inv=$(pg psql -h /tmp -p "$port" -At -d bench -c "select (select sum(abalance) from pgbench_accounts)=(select sum(tbalance) from pgbench_tellers) and (select sum(tbalance) from pgbench_tellers)=(select sum(bbalance) from pgbench_branches)" 2>&1)
    gaps=$(pg psql -h /tmp -p "$port" -At -d bench -c "select coalesce(max(n),0)-count(*) from counter" 2>&1)
    local rows; rows=$(pg psql -h /tmp -p "$port" -At -d bench -c "select count(*) from counter" 2>&1)
    pg pg_ctl -D "$dd" -m fast -w stop >/dev/null 2>&1
    if [ "$inv" = t ] && [ "$gaps" = 0 ]; then say "$label: OK  (recovered in ${up}s, invariant holds, counter has ${rows} rows and no gaps)"; ok=$((ok + 1))
    else say "$label: FAIL (invariant=$inv gaps=$gaps)"; bad=$((bad + 1)); fi
}

# Negative control: copying the files of a running cluster with cp (not atomic) must NOT be a valid backup. If these copies recover
# as well as the snapshots do, the check above cannot tell a good backup from a bad one.
control_check() { # control_check <datadir> <port> <label>
    local b0=$bad o0=$ok broke=0
    check_cluster "$@" > /tmp/ctrl.out
    [ "$bad" -gt "$b0" ] && broke=1
    bad=$b0; ok=$o0
    sed 's/^/  (control) /' /tmp/ctrl.out
    CTRL_N=$((CTRL_N + 1)); CTRL_BROKE=$((CTRL_BROKE + broke))
}

run_load() { # run_load <datadir> <port>: start the cluster, initialise pgbench, start a counter writer and pgbench in the background
    local dd=$1 port=$2
    pg initdb -D "$dd" >/dev/null 2>&1
    pg pg_ctl -D "$dd" -o "-p $port -k /tmp -c listen_addresses='' -c fsync=on -c full_page_writes=on" -w -l "$dd/../pg-main.log" start >/dev/null
    pg createdb -h /tmp -p "$port" bench
    pg pgbench -h /tmp -p "$port" -i -s 5 -q bench >/dev/null 2>&1
    pg psql -h /tmp -p "$port" -q -d bench -c "create table counter(n bigint primary key, ts timestamptz default now())" >/dev/null
    ( i=0; while :; do i=$((i + 1)); pg psql -h /tmp -p "$port" -q -d bench -c "insert into counter(n) values ($i)" >/dev/null 2>&1 || break; done ) &
    echo $! > /tmp/counter.pid
    pg pgbench -h /tmp -p "$port" -c 4 -j 2 -T 120 -n bench >/dev/null 2>&1 &
    echo $! > /tmp/pgbench.pid
}
stop_load() { kill "$(cat /tmp/counter.pid)" "$(cat /tmp/pgbench.pid)" 2>/dev/null; wait 2>/dev/null; }

t_zfs() {
    modprobe zfs; zpool destroy -f tpg 2>/dev/null; wipefs -a "$D-TPXTRA0003" >/dev/null 2>&1
    zpool create -f -o ashift=12 -m /mnt/pgz tpg "$D-TPXTRA0003"; zfs create tpg/pg
    mkdir -p /mnt/pgz/pg/d; chown -R postgres:postgres /mnt/pgz/pg; chmod 700 /mnt/pgz/pg/d
    run_load /mnt/pgz/pg/d 5441
    sleep 8
    for c in 1 2 3; do cp -a /mnt/pgz/pg/d /mnt/pgz/fuzzy$c; sleep 1; done    # the control: plain file copies while writing
    for i in $(seq 1 "$N"); do sleep $((RANDOM % 8 + 3)); zfs snapshot tpg/pg@s$i; done
    sleep 2; stop_load; pg pg_ctl -D /mnt/pgz/pg/d -m immediate stop >/dev/null 2>&1    # an abrupt stop of the live cluster too
    say "snapshots taken while writing: $(zfs list -H -t snapshot -o name tpg/pg | wc -l)"
    for i in $(seq 1 "$N"); do
        zfs clone tpg/pg@s$i tpg/restore$i -o mountpoint=/mnt/pgz/restore$i
        chown -R postgres:postgres /mnt/pgz/restore$i; check_cluster /mnt/pgz/restore$i/d $((5450 + i)) "zfs snapshot s$i"
    done
    check_cluster /mnt/pgz/pg/d 5442 "zfs live cluster after an abrupt stop"
    for c in 1 2 3; do control_check /mnt/pgz/fuzzy$c $((5460 + c)) "plain copy $c (not a snapshot)"; done
    zpool destroy -f tpg
}

t_btrfs() {
    umount /mnt/pgb 2>/dev/null; wipefs -a "$D-TPXTRA0002" >/dev/null 2>&1
    mkfs.btrfs -q -f "$D-TPXTRA0002"; mkdir -p /mnt/pgb; mount "$D-TPXTRA0002" /mnt/pgb
    btrfs subvolume create /mnt/pgb/pg >/dev/null
    mkdir -p /mnt/pgb/pg/d; chown -R postgres:postgres /mnt/pgb/pg; chmod 700 /mnt/pgb/pg/d
    run_load /mnt/pgb/pg/d 5441
    sleep 8
    for c in 1 2 3; do cp -a /mnt/pgb/pg/d /mnt/pgb/fuzzy$c; sleep 1; done    # the control: plain file copies while writing
    for i in $(seq 1 "$N"); do sleep $((RANDOM % 8 + 3)); btrfs subvolume snapshot -r /mnt/pgb/pg /mnt/pgb/snap$i >/dev/null; done
    sleep 2; stop_load; pg pg_ctl -D /mnt/pgb/pg/d -m immediate stop >/dev/null 2>&1
    say "snapshots taken while writing: $N"
    for i in $(seq 1 "$N"); do
        btrfs subvolume snapshot /mnt/pgb/snap$i /mnt/pgb/restore$i >/dev/null
        chown -R postgres:postgres /mnt/pgb/restore$i; check_cluster /mnt/pgb/restore$i/d $((5450 + i)) "btrfs snapshot s$i"
    done
    check_cluster /mnt/pgb/pg/d 5442 "btrfs live cluster after an abrupt stop"
    for c in 1 2 3; do control_check /mnt/pgb/fuzzy$c $((5460 + c)) "plain copy $c (not a snapshot)"; done
    umount /mnt/pgb
}

want=("$@"); [ ${#want[@]} -gt 0 ] || want=(zfs btrfs)
for f in "${want[@]}"; do echo "== $f"; "t_$f"; done
echo; echo "result: $ok recovered correctly, $bad failed"
echo "control: $CTRL_BROKE of $CTRL_N plain copies made while writing were NOT valid backups"
if [ "$CTRL_BROKE" = 0 ]; then echo "CONTROL DID NOT BREAK ANYTHING: this run proves nothing, rerun with more load"; exit 99; fi
[ "$bad" = 0 ]
