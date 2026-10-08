#!/usr/bin/env bash
# =============================================================================
# lab/experiments/offsite-bakeoff.sh — file-level offsite backup tools under the same scenario. Runs INSIDE a lab VM, as root. Lab scaffolding, not part of the system.
#
# Candidates (tool@backend): restic@s3, restic@rest (append-only), borg@ssh (full access), borg@append (append-only), kopia@s3
# Scenario, per candidate (a stand-in data set: incompressible "photos", small "documents", "music"):
#   O1  first backup: time and repository size
#   O2  then 5 files rewritten, 10 added, 5 deleted: second backup: time and growth of the repository
#   O3  restore the latest state to an empty directory and compare every byte with the source
#   O4  restore the FIRST state (history is kept) and compare with the first copy
#   O5  a wrong passphrase must be refused
#   O6  attacker with the client's credentials tries to delete history: is it refused, and is the data still restorable?
#   G   lines of our own configuration (the env and the commands that a NixOS module would carry)
# Integrity (corrupting a repository file and running the tool's check) runs on a repository in a local directory for every tool: t_<tool>_integrity
#
# Usage (inside the VM):  S3_KEY=... S3_SECRET=... sudo -E bash offsite-bakeoff.sh [restic-s3 restic-rest borg-ssh borg-append kopia-s3 ...]
# =============================================================================
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH
export HOME=/root   # kopia and ssh need it, and a systemd unit does not set it
SRC=/srv/data; S1=/srv/copy1; S2=/srv/copy2; OUT=/srv/restore
PW=lab-only-passphrase
declare -A RES
say() { printf '  %s\n' "$*"; }
now() { date +%s.%N; }
el() { awk -v a="$1" -v b="$(now)" 'BEGIN{printf "%.1f", b-a}'; }
mb() { awk -v b="$1" 'BEGIN{printf "%.1f", b/1048576}'; }
dirbytes() { du -sb "$1" 2>/dev/null | cut -f1; }
GARAGE() { GARAGE_RPC_SECRET=0000000000000000000000000000000000000000000000000000000000000000 garage "$@"; }
s3_bucket() { # s3_bucket <name>: a fresh bucket for the run
    GARAGE bucket create "$1" >/dev/null 2>&1; GARAGE bucket allow --read --write --owner "$1" --key pgkey >/dev/null 2>&1
}
s3_bytes() { GARAGE bucket info "$1" 2>/dev/null | awk '/^Size:/{v=$2; u=$3; if(u ~ /GiB/) v*=1073741824; else if(u ~ /MiB/) v*=1048576; else if(u ~ /KiB/) v*=1024; printf "%d", v}'; }
GLUE() { echo "$1"; }

make_data() {
    rm -rf "$SRC" "$S1" "$S2" "$OUT"; mkdir -p "$SRC"/{photos,docs,music}
    for i in $(seq 1 120); do head -c 2097152 /dev/urandom > "$SRC/photos/p$i.jpg"; done
    for i in $(seq 1 1500); do seq 1 $((i % 40 + 10)) | sed "s/^/doc $i line /" > "$SRC/docs/d$i.txt"; done
    for i in $(seq 1 20); do head -c 4194304 /dev/urandom > "$SRC/music/m$i.flac"; done
    cp -a "$SRC" "$S1"
}
mutate() {
    for i in 3 17 42 77 101; do head -c 2097152 /dev/urandom > "$SRC/photos/p$i.jpg"; done
    for i in $(seq 121 130); do head -c 2097152 /dev/urandom > "$SRC/photos/p$i.jpg"; done
    for i in 5 6 7 8 9; do rm -f "$SRC/docs/d$i.txt"; done
    rm -rf "$S2"; cp -a "$SRC" "$S2"
}
same() { diff -r "$1" "$2" >/dev/null 2>&1 && echo identical || echo DIFFERENT; }

# ---------------------------------------------------------------- generic scenario
scenario() { # scenario <cand>  needs t_<cand>_{init,backup,restore,wrongpass,attack,size}
    local c=$1 t0 b1 b2 s_a s_b s_c
    echo "== $c"
    ! declare -F "t_${c}_env" >/dev/null || "t_${c}_env"
    make_data
    "t_${c}_init" >/tmp/off-$c.init.log 2>&1 || { say "$c: INIT FAILED (/tmp/off-$c.init.log)"; return; }
    t0=$(now); "t_${c}_backup" >/tmp/off-$c.b1.log 2>&1; local rc1=$?; b1=$(el "$t0"); s_a=$("t_${c}_size")
    [ $rc1 -eq 0 ] || { say "$c O1: FAIL (exit $rc1, /tmp/off-$c.b1.log)"; return; }
    say "$c O1: first backup ${b1}s, repository $(mb "$s_a") MB (data $(mb "$(dirbytes "$SRC")") MB)"
    RES[$c/O1]="${b1}s, $(mb "$s_a") MB"
    mutate
    t0=$(now); "t_${c}_backup" >/tmp/off-$c.b2.log 2>&1; b2=$(el "$t0"); s_b=$("t_${c}_size")
    say "$c O2: second backup ${b2}s, repository grew by $(mb $((s_b - s_a))) MB (changed and new data: 30 MB)"
    RES[$c/O2]="${b2}s, +$(mb $((s_b - s_a))) MB"
    rm -rf "$OUT"; mkdir -p "$OUT/latest"; t0=$(now); "t_${c}_restore" "$OUT/latest" latest >/tmp/off-$c.r1.log 2>&1; local rt; rt=$(el "$t0")
    say "$c O3: restore latest in ${rt}s: $(same "$S2" "$(t_${c}_path "$OUT/latest")")"; RES[$c/O3]="$(same "$S2" "$(t_${c}_path "$OUT/latest")") ${rt}s"
    mkdir -p "$OUT/first"; "t_${c}_restore" "$OUT/first" first >/tmp/off-$c.r2.log 2>&1
    say "$c O4: restore of the first state: $(same "$S1" "$(t_${c}_path "$OUT/first")")"; RES[$c/O4]="$(same "$S1" "$(t_${c}_path "$OUT/first")")"
    if "t_${c}_wrongpass" >/tmp/off-$c.wp.log 2>&1; then say "$c O5: WRONG PASSPHRASE ACCEPTED"; RES[$c/O5]="ACCEPTED"; else say "$c O5: wrong passphrase refused"; RES[$c/O5]="refused"; fi
    local att; att=$("t_${c}_attack" 2>&1 | tail -n 1); say "$c O6: $att"; RES[$c/O6]="$att"
}

# ---------------------------------------------------------------- restic
export RESTIC_PASSWORD=$PW
RESTIC_BASE="restic --quiet"
t_restic_path() { echo "$1$SRC"; }
t_restic_restore() { $RESTIC_BASE restore "$([ "$2" = first ] && $RESTIC_BASE snapshots --json | jq -r '.[0].short_id' || echo latest)" --target "$1" 2>&1; }
# restic@s3
t_restic-s3_init() { RB=restic-$(date +%s); s3_bucket "$RB"; export RESTIC_REPOSITORY=s3:http://127.0.0.1:3900/$RB AWS_ACCESS_KEY_ID=$S3_KEY AWS_SECRET_ACCESS_KEY=$S3_SECRET AWS_DEFAULT_REGION=garage; restic init; }
t_restic-s3_backup() { restic --quiet backup "$SRC"; }
t_restic-s3_size() { s3_bytes "$RB"; }
t_restic-s3_path() { t_restic_path "$@"; }
t_restic-s3_restore() { t_restic_restore "$@"; }
t_restic-s3_wrongpass() { RESTIC_PASSWORD=wrong restic snapshots; }
t_restic-s3_attack() { local o n; o=$(restic forget --prune --keep-last 1 $(restic snapshots --json | jq -r '.[0].short_id') 2>&1 | tail -n 2); restic forget --prune $(restic snapshots --json | jq -r '.[].short_id') >/dev/null 2>&1; n=$(restic snapshots --json 2>/dev/null | jq length); echo "snapshots left after the attacker's delete-all: $n (an S3 key that can write can delete, unless the bucket has object lock)"; }
# restic@rest (append-only server)
t_restic-rest_init() { export RESTIC_REPOSITORY=rest:http://127.0.0.1:8000/repo-$(date +%s); restic init; RR=${RESTIC_REPOSITORY##*/}; }
t_restic-rest_backup() { restic --quiet backup "$SRC"; }
t_restic-rest_size() { dirbytes /var/lib/restic/$RR; }
t_restic-rest_path() { t_restic_path "$@"; }
t_restic-rest_restore() { t_restic_restore "$@"; }
t_restic-rest_wrongpass() { RESTIC_PASSWORD=wrong restic snapshots; }
t_restic-rest_attack() { restic forget --prune $(restic snapshots --json | jq -r '.[].short_id') >/dev/null 2>&1; local n; n=$(restic snapshots --json 2>/dev/null | jq length); echo "snapshots left after the attacker's delete-all: $n (append-only REST server)"; }

# ---------------------------------------------------------------- borg over ssh
BORG_RSH_FULL="ssh -i /root/.ssh/lab-borg -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
BORG_RSH_APPEND="ssh -i /root/.ssh/lab-borg-append -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
export BORG_DELETE_I_KNOW_WHAT_I_AM_DOING=YES
export BORG_PASSPHRASE=$PW BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
t_borg_path() { echo "$1$SRC"; }
t_borg_restore() { local a; if [ "$2" = first ]; then a=$(borg list --short "$BR" | head -n 1); else a=$(borg list --short "$BR" | tail -n 1); fi; (cd "$1" && borg extract "$BR::$a"); }
# borg@ssh (full access)
t_borg-ssh_env() { export BORG_RSH=$BORG_RSH_FULL; }
t_borg-ssh_init() { BR=ssh://borg@127.0.0.1:2222/./; borg init --encryption=repokey-blake2 "$BR"; }
t_borg-ssh_backup() { borg create --compression lz4 "$BR::$(date +%s%N)" "$SRC"; }
t_borg-ssh_size() { dirbytes /var/lib/borg-full; }
t_borg-ssh_path() { t_borg_path "$@"; }
t_borg-ssh_restore() { t_borg_restore "$@"; }
t_borg-ssh_wrongpass() { BORG_PASSPHRASE=wrong borg list "$BR"; }
t_borg-ssh_attack() { borg delete --force "$BR" >/dev/null 2>&1; if borg list --short "$BR" >/dev/null 2>&1; then echo "repository still there after the attacker's delete"; else echo "repository deleted with the client's own credentials (full-access key)"; fi; }
# borg@append (append-only)
t_borg-append_env() { export BORG_RSH=$BORG_RSH_APPEND; }
t_borg-append_init() { BR=ssh://borg@127.0.0.1:2222/./; borg init --encryption=repokey-blake2 "$BR"; }   # the key of this repo is authorized append-only on the server
t_borg-append_backup() { t_borg-ssh_backup; }
t_borg-append_size() { dirbytes /var/lib/borg-append; }
t_borg-append_path() { t_borg_path "$@"; }
t_borg-append_restore() { t_borg_restore "$@"; }
t_borg-append_wrongpass() { BORG_PASSPHRASE=wrong borg list "$BR"; }
t_borg-append_attack() { borg delete --force "$BR" >/dev/null 2>&1; local n m; n=$(borg list --short "$BR" 2>/dev/null | wc -l); m=$(mktemp -d); if (cd "$m" && borg extract "$BR::$(borg list --short "$BR" | tail -n 1)" >/dev/null 2>&1); then echo "after the attacker's delete: $n archives listed and the latest one restores (append-only key)"; else echo "after the attacker's delete: $n archives listed, restore FAILED"; fi; rm -rf "$m"; }

# ---------------------------------------------------------------- kopia over S3
export KOPIA_PASSWORD=$PW KOPIA_CHECK_FOR_UPDATES=false KOPIA_CONFIG_PATH=/root/.config/kopia/repository.config
t_kopia-s3_init() { KB=kopia-$(date +%s); s3_bucket "$KB"; kopia repository create s3 --bucket="$KB" --endpoint=127.0.0.1:3900 --disable-tls --access-key="$S3_KEY" --secret-access-key="$S3_SECRET" --region=garage --no-check-for-updates 2>&1; }
t_kopia-s3_backup() { kopia snapshot create "$SRC" --no-progress 2>&1; }
t_kopia-s3_size() { s3_bytes "$KB"; }
t_kopia-s3_path() { echo "$1/data"; }
t_kopia-s3_restore() { local id; if [ "$2" = first ]; then id=$(kopia snapshot list --json "$SRC" 2>/dev/null | jq -r 'sort_by(.startTime)|.[0].id'); else id=$(kopia snapshot list --json "$SRC" 2>/dev/null | jq -r 'sort_by(.startTime)|.[-1].id'); fi; kopia restore "$id" "$1/data" --no-progress 2>&1; }
t_kopia-s3_wrongpass() { KOPIA_PASSWORD=wrong kopia repository connect s3 --bucket="$KB" --endpoint=127.0.0.1:3900 --disable-tls --access-key="$S3_KEY" --secret-access-key="$S3_SECRET" --region=garage --config-file=/tmp/kopia-wrong.config 2>&1; }
t_kopia-s3_attack() { kopia snapshot delete --all-snapshots-for-source --delete "$SRC" >/dev/null 2>&1 || true; local n; n=$(kopia snapshot list --json "$SRC" 2>/dev/null | jq length); echo "with the client's credentials the history can be deleted ($n snapshots left); no append-only mode"; }


# ---------------------------------------------------------------- integrity: one repository file is damaged, then the tool's own check runs (local-directory repositories)
corrupt_one() { # corrupt_one <dir>: flip bytes in the middle of the largest file
    local f; f=$(find "$1" -type f -printf '%s %p\n' | sort -rn | sed -n 1p | cut -d' ' -f2-)
    printf 'XXXXXXXXXXXXXXXX' | dd of="$f" bs=1 seek=1000 conv=notrunc status=none; echo "$f"
}
integrity() {
    echo "== integrity"
    make_data; local R=/srv/irepo out
    # restic
    rm -rf $R; export RESTIC_REPOSITORY=$R; restic init >/dev/null 2>&1; restic backup --quiet "$SRC" 2>&1
    out=$(restic check 2>&1 | tail -n 1); say "restic, before damage: $out"
    corrupt_one $R/data >/dev/null; out=$(restic check --read-data 2>&1 | grep -iE "error|fail|damaged|invalid|mismatch|Fatal" | head -n 1); say "restic check --read-data after damage: ${out:-NOT DETECTED}"; RES[restic/integrity]="${out:-NOT DETECTED}"
    # borg
    rm -rf $R; export BORG_RSH=; borg init --encryption=repokey-blake2 $R >/dev/null 2>&1; borg create --compression lz4 "$R::a" "$SRC" 2>&1
    out=$(borg check $R 2>&1 | tail -n 1); say "borg, before damage: ${out:-ok}"
    corrupt_one $R/data >/dev/null; out=$(borg check --verify-data $R 2>&1 | grep -iE "error|corrupt|invalid|fail|integrity" | head -n 1); say "borg check --verify-data after damage: ${out:-NOT DETECTED}"; RES[borg/integrity]="${out:-NOT DETECTED}"
    # kopia
    rm -rf $R; kopia repository create filesystem --path=$R --no-check-for-updates >/dev/null 2>&1; kopia snapshot create "$SRC" --no-progress >/dev/null 2>&1
    out=$(kopia snapshot verify --verify-files-percent=100 2>&1 | tail -n 1); say "kopia, before damage: $out"
    corrupt_one $R/p >/dev/null; out=$(kopia snapshot verify --verify-files-percent=100 2>&1 | grep -iE "error|fail|corrupt|invalid|mismatch" | head -n 1); say "kopia snapshot verify after damage (it can read from its local cache): ${out:-NOT DETECTED}"; out2=$(kopia content verify --full 2>&1 | grep -iE "corrupt|error" | head -n 1); say "kopia content verify --full after damage: ${out2:-NOT DETECTED}"; out="${out:+verify: $out; }content verify: ${out2:-NOT DETECTED}"; RES[kopia/integrity]="${out:-NOT DETECTED}"
}

want=("$@"); [ ${#want[@]} -gt 0 ] || want=(restic-s3 restic-rest borg-ssh borg-append kopia-s3)
for c in "${want[@]}"; do if [ "$c" = integrity ]; then integrity; else scenario "$c"; fi; done
echo; echo "== summary"
for k in $(printf '%s\n' "${!RES[@]}" | sort); do printf '  %-22s %s\n' "$k" "${RES[$k]}"; done
