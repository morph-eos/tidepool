#!/usr/bin/env bash
# =============================================================================
# lab/majors-u15-postgres.sh — ADR 0017: PostgreSQL 17 -> 18 on the lab host's data (Nextcloud, Vaultwarden, Immich with VectorChord indexes) with pg_upgrade, then pgBackRest.
# Runs INSIDE the lab host as root; /home/lab/nixos is the flake (modules/database.nix names postgresql_17 once). The old cluster stays untouched (copy mode): it is the way back.
# =============================================================================
set -uo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH
export NIX_CONFIG='experimental-features = nix-command flakes
download-attempts = 60'
ms() { echo $(( $(date +%s%N) / 1000000 )); }
say() { echo "$(date +%H:%M:%S) $*"; }
pgb() { sudo -u postgres pgbackrest "$@" 2>&1; }
rows() { for d in nextcloud vaultwarden immich; do printf "%s=%s " $d "$(sudo -u postgres psql -d $d -Atc "select count(*) from information_schema.tables where table_schema='public'")/$(sudo -u postgres psql -d $d -Atc "select coalesce(sum(n_live_tup),0)::bigint from pg_stat_user_tables")"; done; echo; }
mkpg() { nix build --impure --no-link --print-out-paths --expr "let p=(builtins.getFlake \"path:/home/lab/nixos\").nixosConfigurations.lab.pkgs; in p.postgresql_$1.withPackages (ps: [ ps.pgvector ps.vectorchord ])" 2>&1 | tail -n 1; }
say "== before"; say "tables/rows: $(rows)"; say "immich vchordrq index: $(sudo -u postgres psql -d immich -Atc "select count(*) from pg_indexes where indexdef ilike '%vchordrq%'")"
sudo -u postgres psql -d immich -Atc "select count(*) from face_search" >/dev/null 2>&1
OLD=$(mkpg 17); NEW=$(mkpg 18); say "old $($OLD/bin/postgres --version) | new $($NEW/bin/postgres --version)"
say "== stop everything that uses the database"
systemctl stop podman-immich-server podman-immich-redis phpfpm-nextcloud vaultwarden pgbackrest-default-weekly.timer pgbackrest-default-daily.timer 2>/dev/null; systemctl stop postgresql
s=$(ms)
install -d -m 0700 -o postgres -g postgres /var/lib/postgresql/18
LCC=$(sudo -u postgres $OLD/bin/pg_controldata /var/lib/postgresql/17 | grep -E "LC_COLLATE|checksum" | tr -s ' ' | tr '\n' ' '); say "old cluster: $LCC"
sudo -u postgres $NEW/bin/initdb -D /var/lib/postgresql/18 --encoding=UTF8 --locale=C.UTF-8 --no-data-checksums -U postgres >/tmp/initdb.log 2>&1; say "initdb: $(tail -n 1 /tmp/initdb.log | cut -c1-80)"
mkdir -p /tmp/pgup; chown postgres /tmp/pgup; cd /tmp/pgup
UP="sudo -u postgres $NEW/bin/pg_upgrade --old-datadir /var/lib/postgresql/17 --new-datadir /var/lib/postgresql/18 --old-bindir $OLD/bin --new-bindir $NEW/bin --socketdir /tmp/pgup --new-options=-cshared_preload_libraries=vchord.so --old-options=-cshared_preload_libraries=vchord.so"
$UP --check >/tmp/pgup-check.log 2>&1; say "pg_upgrade --check: exit $? ; $(tail -n 2 /tmp/pgup-check.log | tr '\n' ' ' | cut -c1-140)"
t0=$(ms); $UP >/tmp/pgup.log 2>&1; rc=$?; say "pg_upgrade (copy mode): exit $rc in $(( ($(ms) - t0) / 1000 )) s; $(grep -E 'Upgrade Complete|error|ERROR|FATAL' /tmp/pgup.log | head -n 3 | tr '\n' ' ' | cut -c1-160)"
[ $rc -ne 0 ] && { tail -n 25 /tmp/pgup.log | cut -c1-200; exit 1; }
du -sh /var/lib/postgresql/17 /var/lib/postgresql/18 | tr '\n' ' '; echo
say "== switch the configuration to PostgreSQL 18"
sed -i 's/pkgs.postgresql_17/pkgs.postgresql_18/' /home/lab/nixos/modules/database.nix
t1=$(ms); nixos-rebuild test --flake path:/home/lab/nixos#lab 2>&1 | grep -v "^evaluation warning" | grep -E "error|Done|failed" | head -n 3 | cut -c1-200
sleep 20; say "switch: $(( ($(ms) - t1) / 1000 )) s; server: $(sudo -u postgres psql -Atc 'select version()' | cut -c1-40); data dir: $(sudo -u postgres psql -Atc 'show data_directory'); failed units: $(systemctl --failed --no-legend | tr -s ' ' | cut -d' ' -f2 | tr '\n' ' ')"
say "tables/rows after: $(rows)"
say "vchordrq indexes after: $(sudo -u postgres psql -d immich -Atc "select count(*) from pg_indexes where indexdef ilike '%vchordrq%'"); extensions: $(sudo -u postgres psql -d immich -Atc "select extname||' '||extversion from pg_extension where extname in ('vector','vchord')" | tr '\n' ' ')"
say "a vector search on the upgraded index: $(sudo -u postgres psql -d immich -Atc "set enable_seqscan=off; explain select 1 from face_search order by embedding <=> (select embedding from face_search limit 1) limit 1" 2>&1 | head -n 3 | tr '\n' '|' | cut -c1-140)"
say "services: immich $(curl -s -m 10 -o /dev/null -w '%{http_code}' 127.0.0.1:2283/api/server/ping); nextcloud $(curl -sk -m 10 --resolve cloud.lab.test:443:10.0.2.15 https://cloud.lab.test/status.php | head -c 60); vaultwarden $(curl -s -m 10 -o /dev/null -w '%{http_code}' 127.0.0.1:8222/alive)"
say "== pgBackRest after the major"
say "archive-push right after the switch: $(sudo -u postgres psql -Atc 'select last_failed_wal is not null, failed_count from pg_stat_archiver')   (true = archiving failed)"
pgb info | sed -n 1,8p
say "stanza-upgrade: $(pgb --stanza=default stanza-upgrade | tail -n 2 | tr '\n' ' ' | cut -c1-160)"
sudo -u postgres psql -Atc "select pg_switch_wal()" >/dev/null; sleep 8
say "check: $(pgb --stanza=default check | tail -n 2 | tr '\n' ' ' | cut -c1-140)"
t2=$(ms); pgb --stanza=default --type=full backup >/tmp/pgb.log; say "a full backup of 18: exit $? in $(( ($(ms) - t2) / 1000 )) s; $(pgb info | grep -E 'status|full backup:|database size' | head -n 3 | tr -s ' ' | tr '\n' ' ' | cut -c1-200)"
say "verify: $(pgb --stanza=default verify | grep -E 'status|error' | head -n 2 | tr '\n' ' ')"
systemctl start pgbackrest-default-weekly.timer pgbackrest-default-daily.timer 2>/dev/null
say "== the monthly restore test (verify.nix) against the new major"
t3=$(ms); systemctl start pgbackrest-restore-test 2>&1 | tail -n 2; for i in $(seq 1 120); do systemctl is-active -q pgbackrest-restore-test || break; sleep 3; done
say "restore test: $(systemctl show pgbackrest-restore-test -p Result --value) in $(( ($(ms) - t3) / 1000 )) s; $(journalctl -u pgbackrest-restore-test --no-pager -o cat | grep -iE 'amcheck|restore|row|ok|error' | tail -n 3 | tr '\n' ' ' | cut -c1-200)"
say done
