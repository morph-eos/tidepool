#!/usr/bin/env bash
# =============================================================================
# lab/majors-u15-postgres-check.sh — after lab/majors-u15-postgres.sh: exact row counts of EVERY table in the old (17, untouched) and new (18) cluster, pgBackRest verify,
# and the way back: the configuration to 17 again, pgBackRest told with stanza-upgrade. Runs INSIDE the lab host as root.
# =============================================================================
set -uo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH
export NIX_CONFIG='experimental-features = nix-command flakes'
say() { echo "$(date +%H:%M:%S) $*"; }
mkpg() { nix build --impure --no-link --print-out-paths --expr "let p=(builtins.getFlake \"path:/home/lab/nixos\").nixosConfigurations.lab.pkgs; in p.postgresql_$1.withPackages (ps: [ ps.pgvector ps.vectorchord ])" 2>&1 | tail -n 1; }
OLD=$(mkpg 17)
counts() { # $1 = psql command prefix
  for d in nextcloud vaultwarden immich; do
    $1 -d $d -Atc "select table_name from information_schema.tables where table_schema='public' and table_type='BASE TABLE' order by 1" | while read t; do echo "$d.$t=$($1 -d $d -Atc "select count(*) from \"$t\"")"; done
  done
}
say "== exact counts, new cluster (18)"; counts "sudo -u postgres psql" > /tmp/counts18.txt; wc -l < /tmp/counts18.txt | sed 's/^/tables: /'
say "== the old cluster (17), started on another port by hand, read only"
mkdir -p /tmp/pgup; chown postgres /tmp/pgup
sudo -u postgres $OLD/bin/pg_ctl -D /var/lib/postgresql/17 -o "-p 5433 -k /tmp/pgup -c shared_preload_libraries=vchord.so -c archive_mode=off" -w start >/dev/null 2>&1
counts "sudo -u postgres $OLD/bin/psql -h /tmp/pgup -p 5433" > /tmp/counts17.txt; sudo -u postgres $OLD/bin/pg_ctl -D /var/lib/postgresql/17 -m fast stop >/dev/null 2>&1
say "old: $(wc -l < /tmp/counts17.txt) tables; differences with the new one: $(diff /tmp/counts17.txt /tmp/counts18.txt | grep -c '^[<>]')   (rows in total: $(awk -F= '{s+=$2} END {print s}' /tmp/counts18.txt))"
diff /tmp/counts17.txt /tmp/counts18.txt | head -n 6
say "== pgBackRest verify"; sudo -u postgres pgbackrest --stanza=default verify 2>&1 | tail -n 4 | cut -c1-200
sudo -u postgres pgbackrest info 2>&1 | grep -E "db \(|wal archive|full backup:" | head -n 6
say "== the way back: configuration to 17 (the old cluster was not started with archiving, its data is as before the move)"
systemctl stop podman-immich-server phpfpm-nextcloud vaultwarden 2>/dev/null
sed -i 's/pkgs.postgresql_18/pkgs.postgresql_17/' /home/lab/nixos/modules/database.nix
s=$(date +%s); nixos-rebuild test --flake path:/home/lab/nixos#lab 2>&1 | grep -E "error|Done|failed" | head -n 2 | cut -c1-160; sleep 15
say "back on: $(sudo -u postgres psql -Atc 'select version()' | cut -c1-30), $(( $(date +%s) - s )) s; archiving state: $(sudo -u postgres psql -Atc 'select failed_count from pg_stat_archiver') failures"
sudo -u postgres psql -Atc "select pg_switch_wal()" >/dev/null; sleep 6
say "pgbackrest check without telling it: $(sudo -u postgres pgbackrest --stanza=default check 2>&1 | grep -E 'ERROR|successfully' | head -n 1 | cut -c1-200)"
say "stanza-upgrade back: $(sudo -u postgres pgbackrest --stanza=default stanza-upgrade 2>&1 | grep -E 'ERROR|completed' | head -n 1 | cut -c1-160); check: $(sudo -u postgres pgbackrest --stanza=default check 2>&1 | grep -cE 'ERROR')  errors"
say "services: immich $(curl -s -m 10 -o /dev/null -w '%{http_code}' 127.0.0.1:2283/api/server/ping); vaultwarden $(curl -s -m 10 -o /dev/null -w '%{http_code}' 127.0.0.1:8222/alive)"
say done
