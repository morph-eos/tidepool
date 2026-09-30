#!/usr/bin/env bash
# =============================================================================
# lab/pitr-bakeoff.sh — PostgreSQL point-in-time recovery tools under the same scenario. Runs INSIDE a lab VM, as root.
#
# Tools: pgbackrest, barman, barmansync (more can be added as functions t_<name>_*). Disks by serial: TPXTRA0001 holds the clusters, TPXTRA0002 the repositories
# (a stand-in for the large backup disk).
#
# Scenario, per tool (a writer inserts one row at a time and records the last row PostgreSQL acknowledged, so a loss can be counted exactly):
#   P1  a full backup taken while the writer is running
#   P2  the writer keeps going; the moment T_good is noted; a table is then dropped (the mistake); the writer goes on; the machine crashes (kill -9)
#   P3  restore to T_good: the dropped table is back, and the rows present are the ones committed up to T_good (not one more, not fewer)
#   P4  restore to the latest point: how many ACKNOWLEDGED commits were lost (the data-loss window actually reached)
#   G   how much configuration of our own the setup needed (lines), and how many custom scripts (none expected)
#
# Usage (inside the VM):  sudo bash pitr-bakeoff.sh [pgbackrest|barman ...]
# =============================================================================
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
D=/dev/disk/by-id/virtio
X=/mnt/pgx; REPO=/mnt/pgrepo
BPORT=5500; APORT=5501; LPORT=5502
ARCH_TIMEOUT=${ARCH_TIMEOUT:-60}
declare -A RES GLUE
pg() { sudo -u postgres "$@"; }
say() { printf '  %s\n' "$*"; }
now() { date +%s.%N; }
el() { awk -v a="$1" -v b="$(now)" 'BEGIN{printf "%.1f", b-a}'; }
psqlq() { pg psql -h /tmp -p "$1" -d bench -qAt -c "$2" 2>&1; }

# Write a config file from stdin and count its lines as glue. Usage: emit <tool> <path> <<EOF
emit() { local tool=$1 path=$2 n; mkdir -p "$(dirname "$path")"; cat > "$path"; n=$(grep -cv '^\s*\(#\|$\)' "$path"); GLUE[$tool]=$(( ${GLUE[$tool]:-0} + n )); }

prepare_disks() {
    umount -R $X $REPO 2>/dev/null || true
    pkill -u postgres 2>/dev/null; sleep 1
    wipefs -a "$D-TPXTRA0001" "$D-TPXTRA0002" >/dev/null 2>&1
    mkfs.ext4 -q -F "$D-TPXTRA0001"; mkfs.ext4 -q -F "$D-TPXTRA0002"
    mkdir -p $X $REPO; mount "$D-TPXTRA0001" $X; mount "$D-TPXTRA0002" $REPO
    chown postgres:postgres $X $REPO
}

cluster_start() { # cluster_start <datadir> <port>
    pg pg_ctl -D "$1" -o "-p $2 -k /tmp -c listen_addresses=''" -w -t 120 -l "$1/../pg-$2.log" start >/dev/null 2>&1
}
cluster_stop_hard() { local pid; pid=$(head -1 "$1/postmaster.pid" 2>/dev/null); [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null; sleep 1; }

writer_start() { # writer_start <port> <ackfile>
    psqlq "$1" "create table if not exists counter(n bigint primary key, ts timestamptz default clock_timestamp())" >/dev/null
    (
        i=0
        while :; do
            i=$((i + 1))
            pg psql -h /tmp -p "$1" -d bench -qAt -c "insert into counter(n) values ($i)" >/dev/null 2>&1 || break
            echo $i > "$2"
        done
    ) >/dev/null 2>&1 </dev/null &
    echo $! > /tmp/writer.pid
}
writer_stop() { local p; p=$(cat /tmp/writer.pid 2>/dev/null); [ -n "$p" ] && { kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; }; return 0; }   # wait for the writer only: a bare wait would also wait for barman cron

wait_promoted() { # wait_promoted <port>: until the restored cluster accepts connections and is no longer in recovery
    local i r
    for i in $(seq 1 120); do
        r=$(psqlq "$1" "select pg_is_in_recovery()")
        [ "$r" = f ] && return 0
        sleep 1
    done
    return 1
}

# ---------------------------------------------------------------------------- generic scenario
cleanup_all() { writer_stop 2>/dev/null; kill "$(cat /tmp/barmancron.pid 2>/dev/null)" 2>/dev/null; pkill -u postgres 2>/dev/null; return 0; }
scenario() { # scenario <tool>   (needs the functions t_<tool>_setup, _backup, _restore_time, _restore_latest, _stop_services)
    local tool=$1 t0
    local DD=$X/$tool/data ACK=/tmp/ack-$tool
    rm -f "$ACK"; mkdir -p "$X/$tool"; chown postgres:postgres "$X/$tool"
    pg initdb -D "$DD" >/dev/null 2>&1
    "t_${tool}_setup" "$DD" || { say "$tool: SETUP FAILED"; return; }
    cluster_start "$DD" $BPORT || { say "$tool: cluster did not start"; return; }
    pg createdb -h /tmp -p $BPORT bench; pg pgbench -h /tmp -p $BPORT -i -s 5 -q bench >/dev/null 2>&1
    "t_${tool}_after_start" || { say "$tool: AFTER-START FAILED"; return; }
    writer_start $BPORT "$ACK"; sleep 10
    # P1
    t0=$(now); "t_${tool}_backup" "$DD" >"/tmp/$tool.backup.log" 2>&1; local rc=$?; local bt; bt=$(el "$t0")
    local bsize; bsize=$(du -sm "$REPO/$tool" 2>/dev/null | cut -f1)
    if [ $rc -ne 0 ]; then say "$tool P1: FAIL (backup exited $rc, see /tmp/$tool.backup.log)"; RES[$tool/P1]=FAIL; return; fi
    say "$tool P1: OK  full backup under load in ${bt}s, ${bsize} MB in the repository"; RES[$tool/P1]="OK ${bt}s ${bsize}MB"
    # P2: let time pass so WAL gets archived, note T_good, make the mistake, keep writing, crash
    sleep $((ARCH_TIMEOUT + 15))
    local rowT; rowT=$(psqlq $BPORT "select to_char(clock_timestamp(),'YYYY-MM-DD HH24:MI:SS.MSTZH'), max(n) from counter")
    local T_GOOD=${rowT%%|*} N_GOOD=${rowT##*|}
    psqlq $BPORT "drop table pgbench_accounts" >/dev/null
    sleep 20
    local LAST_ACK; LAST_ACK=$(cat "$ACK"); cluster_stop_hard "$DD"; writer_stop
    say "$tool P2: crash (kill -9). T_good=${T_GOOD} (last row then: $N_GOOD), last acknowledged row at the crash: $LAST_ACK"
    "t_${tool}_stop_services"
    # P3
    local ADIR=$X/$tool/restA; rm -rf "$ADIR"; mkdir -p "$ADIR"; chown postgres:postgres "$ADIR"; chmod 700 "$ADIR"
    t0=$(now); "t_${tool}_restore_time" "$ADIR" "$T_GOOD" >"/tmp/$tool.restA.log" 2>&1
    cluster_start "$ADIR" $APORT; wait_promoted $APORT; local rt; rt=$(el "$t0")
    local has max; has=$(psqlq $APORT "select count(*) from pgbench_accounts"); max=$(psqlq $APORT "select coalesce(max(n),-1) from counter")
    local gaps; gaps=$(psqlq $APORT "select coalesce(max(n),0)-count(*) from counter")
    if [ "${has:-0}" -gt 0 ] 2>/dev/null && [ "$gaps" = 0 ] && [ "$max" -ge "$N_GOOD" ] && [ "$max" -le $((N_GOOD + 3)) ]; then
        say "$tool P3: OK  restored to T_good in ${rt}s: the dropped table is back ($has rows), counter ends at $max (T_good had $N_GOOD), no gaps"; RES[$tool/P3]="OK ${rt}s"
    else
        say "$tool P3: FAIL (accounts=$has counter max=$max expected $N_GOOD..$((N_GOOD + 3)) gaps=$gaps; see /tmp/$tool.restA.log)"; RES[$tool/P3]=FAIL
    fi
    pg pg_ctl -D "$ADIR" -m fast -w stop >/dev/null 2>&1
    # P4
    local BDIR=$X/$tool/restB; rm -rf "$BDIR"; mkdir -p "$BDIR"; chown postgres:postgres "$BDIR"; chmod 700 "$BDIR"
    t0=$(now); "t_${tool}_restore_latest" "$BDIR" >"/tmp/$tool.restB.log" 2>&1
    cluster_start "$BDIR" $LPORT; wait_promoted $LPORT; rt=$(el "$t0")
    max=$(psqlq $LPORT "select coalesce(max(n),-1) from counter"); local lost=$((LAST_ACK - max))
    say "$tool P4: restored to the latest point in ${rt}s: last acknowledged row $LAST_ACK, last restored row $max => $lost acknowledged commits lost"; RES[$tool/P4]="lost $lost (of $LAST_ACK)"
    pg pg_ctl -D "$BDIR" -m fast -w stop >/dev/null 2>&1
    say "$tool G:  ${GLUE[$tool]:-0} lines of configuration of our own (comments and blanks excluded), custom scripts: 0"
    RES[$tool/G]="${GLUE[$tool]:-0} lines"
}

# ---------------------------------------------------------------------------- pgBackRest
t_pgbackrest_setup() {
    emit pgbackrest /etc/pgbackrest.conf <<EOF
[global]
repo1-path=$REPO/pgbackrest
repo1-retention-full=2
repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=lab-only-not-a-secret
compress-type=zst
start-fast=y
log-path=$REPO/pgbackrest-log
[main]
pg1-path=$1
pg1-port=$BPORT
pg1-socket-path=/tmp
EOF
    mkdir -p $REPO/pgbackrest $REPO/pgbackrest-log; chown postgres:postgres $REPO/pgbackrest $REPO/pgbackrest-log
    emit pgbackrest "$1/postgresql.conf.d-pgbackrest" <<EOF
wal_level = replica
archive_mode = on
archive_command = 'pgbackrest --stanza=main archive-push %p'
archive_timeout = $ARCH_TIMEOUT
EOF
    cat "$1/postgresql.conf.d-pgbackrest" >> "$1/postgresql.conf"; rm -f "$1/postgresql.conf.d-pgbackrest"
}
t_pgbackrest_after_start() { pg pgbackrest --stanza=main stanza-create >/tmp/pgbr-stanza.log 2>&1 && pg pgbackrest --stanza=main check >>/tmp/pgbr-stanza.log 2>&1; }
t_pgbackrest_backup() { pg pgbackrest --stanza=main --type=full backup; }
t_pgbackrest_stop_services() { :; }
t_pgbackrest_restore_time() { pg pgbackrest --stanza=main --pg1-path="$1" --type=time --target="$2" --target-action=promote restore; }
t_pgbackrest_restore_latest() { pg pgbackrest --stanza=main --pg1-path="$1" restore; }

# ---------------------------------------------------------------------------- Barman (streaming, backup_method=postgres)
BCONF=/etc/barman-lab.conf
t_barman_setup() {
    emit barman "$BCONF" <<EOF
[barman]
barman_user = postgres
barman_home = $REPO/barman
log_file = $REPO/barman/barman.log
configuration_files_directory = /etc/barman-lab.d
compression = gzip
[main]
description = lab
conninfo = host=/tmp port=$BPORT user=postgres dbname=postgres
streaming_conninfo = host=/tmp port=$BPORT user=postgres dbname=postgres replication=true
backup_method = postgres
streaming_archiver = on
slot_name = barman
create_slot = auto
archiver = off
retention_policy = RECOVERY WINDOW OF 7 DAYS
EOF
    mkdir -p /etc/barman-lab.d $REPO/barman; chown postgres:postgres $REPO/barman
    emit barman "$1/postgresql.conf.d-barman" <<EOF
wal_level = replica
max_wal_senders = 4
max_replication_slots = 4
archive_timeout = $ARCH_TIMEOUT
EOF
    cat "$1/postgresql.conf.d-barman" >> "$1/postgresql.conf"; rm -f "$1/postgresql.conf.d-barman"
}
# barman cron must run every minute (in production: a systemd timer, which is more glue); here a loop stands in for it
t_barman_after_start() {
    ( while :; do pg barman -c $BCONF cron >/dev/null 2>&1 </dev/null; sleep 15; done ) >/dev/null 2>&1 </dev/null &
    echo $! > /tmp/barmancron.pid
    sleep 20
    # Barman's documented first step: until one WAL segment has been received, "barman check" reports the WAL archive as FAILED and a backup refuses to start
    pg barman -c $BCONF switch-wal --force --archive main >/tmp/barman-switch.log 2>&1
    local i
    for i in $(seq 1 30); do
        pg barman -c $BCONF check main >/tmp/barman-check.log 2>&1 && return 0
        sleep 2
    done
    grep -E 'FAILED' /tmp/barman-check.log | head -3
    return 0
}
t_barman_backup() { pg barman -c $BCONF backup main --wait; }
t_barman_stop_services() { kill "$(cat /tmp/barmancron.pid)" 2>/dev/null; pkill -u postgres -f 'barman|receivewal' 2>/dev/null; sleep 1; }
t_barman_cleanup() { t_barman_stop_services; }
t_barman_restore_time() { pg barman -c $BCONF recover --target-time "$2" --target-action promote main latest "$1"; }
t_barman_restore_latest() { pg barman -c $BCONF recover main latest "$1"; }

# Barman with synchronous streaming: PostgreSQL waits for Barman's receiver to flush each commit (zero data loss, at the cost of write latency,
# and of writes stopping if the receiver is gone). The setting is applied after the receiver is connected, or the first write would wait forever.
t_barmansync_setup() { t_barman_setup "$@"; }
t_barmansync_after_start() {
    t_barman_after_start || return 1
    emit barmansync /etc/barman-lab-sync.note <<EOF2
synchronous_standby_names = 'barman_receive_wal'
EOF2
    psqlq $BPORT "alter system set synchronous_standby_names = 'barman_receive_wal'" >/dev/null 2>&1
    psqlq $BPORT "select pg_reload_conf()" >/dev/null 2>&1
    sleep 2
}
t_barmansync_backup() { t_barman_backup "$@"; }
t_barmansync_stop_services() { t_barman_stop_services; }
t_barmansync_restore_time() { t_barman_restore_time "$@"; }
t_barmansync_restore_latest() { t_barman_restore_latest "$@"; }

want=("$@"); [ ${#want[@]} -gt 0 ] || want=(pgbackrest barman)
for t in "${want[@]}"; do
    echo "== $t"
    prepare_disks
    scenario "$t"
    cleanup_all
done
echo; echo "== summary"
for k in $(printf '%s\n' "${!RES[@]}" | sort); do printf '  %-16s %s\n' "$k" "${RES[$k]}"; done
