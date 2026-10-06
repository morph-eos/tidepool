#!/usr/bin/env bash
# =============================================================================
# lab/drill-guest.sh <stage> — the restore drill (ADR 0014), the part that runs INSIDE the lab host as root. Driven by lab/restore-drill.sh.
#   wait | seed1 | seed2 | damage | stop-services | restore-files | restore-db | start-services | verify
# State between stages (times, counts, archive names) is in /root/drill-state.env; the driver carries it across the "disaster".
# =============================================================================
set -uo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH
STATE=/root/drill-state.env; touch $STATE
say() { printf '  %s\n' "$*"; }
setv() { sed -i "/^$1=/d" $STATE; echo "$1=\"$2\"" >> $STATE; eval "$1=\"\$2\""; }
. $STATE
IM=http://127.0.0.1:2283
NCPASS=$(cat /run/secrets/nextcloud-admin-pass)
DAVPASS=lab-only-dav-password
export BORG_PASSCOMMAND="cat /run/secrets/borg-passphrase"
pg() { runuser -u postgres -- psql -tA "$@"; }
immich_token() { curl -sf -H 'Content-Type: application/json' -X POST $IM/api/auth/login -d '{"email":"lab@example.com","password":"lab-only-password"}' | jq -r .accessToken; }
immich_ids() { curl -sf -H "Authorization: Bearer $(immich_token)" -H 'Content-Type: application/json' -X POST $IM/api/search/metadata -d '{"size":1000}' | jq -r '.assets.items[].id'; }
put() { local f; f=$(mktemp); printf '%s\n' "$3" > $f; curl -sk -u "$1" -T $f "$2" -o /dev/null; rm -f $f; }
nc() { curl -sk -u root:$NCPASS "$@"; }   # the module's admin user is "root" unless adminuser is set
marker() { for db in immich vaultwarden nextcloud; do pg -d $db -c "create table if not exists drill_marker(note text, at timestamptz default now()); insert into drill_marker(note) values ('$1')" >/dev/null; done; }
first_archive_after_good() { # the first archive of the repository of everything that starts at or after T_GOOD (names carry local start times and sort)
  local t; t=$(date -d "$T_GOOD" +%Y-%m-%dT%H:%M:%S); BORG_REPO=/mnt/backup16/borg-everything borg list --short | sort | awk -v t="tidepool-lab-everything-$t" '$0 >= t {print; exit}'
}
borg_jobs() { # the Borg jobs are not oneshot units: `systemctl start` returns at once, so wait for them to finish
  systemctl start borgbackup-job-everything.service borgbackup-job-offsite.service; sleep 1
  while systemctl is-active --quiet borgbackup-job-everything.service borgbackup-job-offsite.service; do sleep 1; done
}

case "${1:?stage}" in
wait)
  for i in $(seq 1 180); do
    curl -sf $IM/api/server/ping >/dev/null 2>&1 && curl -skf https://cloud.lab.test/status.php | grep -q '"installed":true' && curl -sf http://127.0.0.1:8222/alive >/dev/null && break; sleep 5
  done
  say "services: immich $(curl -sf $IM/api/server/ping | tr -d '\n'), nextcloud $(curl -skf https://cloud.lab.test/status.php | jq -c '{installed,version}'), vaultwarden $(curl -sf http://127.0.0.1:8222/alive | head -c 30)"
  say "failed units: $(systemctl --failed --no-legend | wc -l)"
  ;;
seed1)
  for db in immich vaultwarden nextcloud; do pg -d $db -c 'drop table if exists drill_marker' >/dev/null; done
  bash /tmp/immich-seed.sh $IM /tmp/imgs/a | tail -n 1
  for n in 1 2 3; do put root:$NCPASS https://cloud.lab.test/remote.php/dav/files/root/nc-a$n.txt "nextcloud file a$n"; done
  put lab:$DAVPASS https://backup.lab.test/w-a1.txt "webdav a1"
  incus launch images:alpine/3.24 drill-ct -s smr --quiet >/dev/null 2>&1 </dev/null; for i in $(seq 1 30); do incus exec drill-ct -- true </dev/null 2>/dev/null && break; sleep 2; done; incus exec drill-ct -- sh -c 'echo incus-marker > /root/marker' </dev/null
  say "Incus: an instance on the directory pool of the 2 TB disk: $(incus list drill-ct -f csv -c ns </dev/null)"
  setv RSA_SUM "$(sha256sum /var/lib/vaultwarden/rsa_key.pem | cut -d" " -f1)"
  marker before
  systemctl start pgbackrest-default-weekly.service; say "pgBackRest full backup: $(systemctl is-active pgbackrest-default-weekly.service); backups: $(runuser -u postgres -- pgbackrest --stanza=default info --output=json | jq -c '[.[0].backup[] | .type]')"
  borg_jobs; say "Borg jobs done: $(systemctl is-failed borgbackup-job-everything.service borgbackup-job-offsite.service | tr '\n' ' ')"
  ;;
seed2)
  bash /tmp/immich-seed.sh $IM /tmp/imgs/b | tail -n 1
  for n in 1 2; do put root:$NCPASS https://cloud.lab.test/remote.php/dav/files/root/nc-b$n.txt "nextcloud file b$n"; done
  put lab:$DAVPASS https://backup.lab.test/w-b1.txt "webdav b1"
  marker after-backup1
  sleep 3
  setv T_GOOD "$(pg -c "select to_char(now() at time zone 'utc','YYYY-MM-DD HH24:MI:SS')||'+00'")"
  sleep 2
  borg_jobs
  immich_ids | sort > /root/drill-immich-ids.txt
  setv IMMICH_AT_GOOD "$(wc -l < /root/drill-immich-ids.txt)"
  setv NC_AT_GOOD "$(nc -X PROPFIND -H 'Depth: 1' https://cloud.lab.test/remote.php/dav/files/root/ | grep -o 'nc-[ab][0-9].txt' | sort -u | wc -l)"
  setv ARCHIVE "$(first_archive_after_good)"
  say "T_GOOD=$T_GOOD; Immich assets at that moment: $IMMICH_AT_GOOD; Nextcloud files: $NC_AT_GOOD; the Borg archive taken right after: $ARCHIVE"
  ;;
damage)
  for id in $(head -n 3 /root/drill-immich-ids.txt); do curl -sf -X DELETE -H "Authorization: Bearer $(immich_token)" -H 'Content-Type: application/json' $IM/api/assets -d "{\"ids\":[\"$id\"],\"force\":true}" >/dev/null; done
  nc -X DELETE https://cloud.lab.test/remote.php/dav/files/root/nc-b2.txt -o /dev/null
  rm -f /srv/data/webdav/w-b1.txt
  marker damage
  say "after the damage: Immich assets $(immich_ids | wc -l), markers $(pg -d immich -c "select string_agg(note, ',' order by at) from drill_marker")"
  sleep 40   # the WAL after T_GOOD must reach the repository (archive_timeout is 30 s)
  say "archived WAL after the damage: $(runuser -u postgres -- pgbackrest --stanza=default info --output=json | jq -c '.[0].archive[0].max')"
  ;;
stop-services)
  systemctl stop borgbackup-job-everything.timer borgbackup-job-offsite.timer pgbackrest-default-weekly.timer pgbackrest-default-daily.timer 2>/dev/null
  systemctl stop nginx phpfpm-nextcloud nextcloud-cron.timer nextcloud-update-db vaultwarden podman-immich-server podman-immich-redis syncthing prometheus alertmanager 2>/dev/null
  say "services stopped"
  ;;
restore-files)
  ARCHIVE=$(first_archive_after_good)
  find /srv/data -mindepth 1 -delete; rm -rf /var/lib/vaultwarden
  s=$(date +%s); (cd / && BORG_REPO=/mnt/backup16/borg-everything borg extract --list ::"$ARCHIVE" 2>&1 | tail -n 0)
  say "files restored from $ARCHIVE in $(( $(date +%s) - s )) s: $(find /srv/data -type f | wc -l) files under /srv/data"
  ;;
restore-db)
  systemctl stop postgresql; find /var/lib/postgresql/17 -mindepth 1 -delete 2>/dev/null
  s=$(date +%s)
  runuser -u postgres -- pgbackrest --stanza=default --type=time --target="$T_GOOD" --target-action=promote restore 2>&1 | tail -n 2
  systemctl start postgresql; for i in $(seq 1 60); do pg -c "select 1" >/dev/null 2>&1 && break; sleep 2; done
  say "database restored to $T_GOOD in $(( $(date +%s) - s )) s; markers: immich=$(pg -d immich -c "select string_agg(note, ',' order by at) from drill_marker")"
  ;;
restore-incus)
  # nothing to restore: Incus's state is on the surviving 2 TB disk (bind-mounted at /var/lib/incus), so the rebuilt host finds its instances as they were
  say "Incus on the rebuilt host: incus-preseed $(systemctl is-active incus-preseed), pools: $(incus storage list -f csv -c n </dev/null | tr '\n' ' '), instances: $(incus list -f csv -c ns </dev/null | tr '\n' ' ')"
  ;;
start-services)
  systemctl start postgresql nginx phpfpm-nextcloud vaultwarden podman-immich-redis podman-immich-server syncthing prometheus alertmanager
  systemctl start borgbackup-job-everything.timer borgbackup-job-offsite.timer pgbackrest-default-weekly.timer pgbackrest-default-daily.timer nextcloud-cron.timer 2>/dev/null
  for i in $(seq 1 120); do curl -sf $IM/api/server/ping >/dev/null 2>&1 && break; sleep 3; done
  ;;
verify)
  fail=0; ok() { say "PASS  $*"; }; no() { say "FAIL  $*"; fail=1; }
  n=$(immich_ids | wc -l); [ "$n" = "$IMMICH_AT_GOOD" ] && ok "Immich: $n assets, as at T_GOOD" || no "Immich: $n assets, expected $IMMICH_AT_GOOD"
  miss=0; tok=$(immich_token); for id in $(cat /root/drill-immich-ids.txt); do c=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $tok" $IM/api/assets/$id/original); [ "$c" = 200 ] || miss=$((miss+1)); done
  [ "$miss" = 0 ] && ok "Immich: every original file is served (the three that the damage deleted included)" || no "Immich: $miss originals missing"
  m=$(pg -d immich -c "select string_agg(note, ',' order by at) from drill_marker"); [ "$m" = "before,after-backup1" ] && ok "database markers in immich: $m (no 'damage')" || no "immich markers: $m"
  for db in vaultwarden nextcloud; do m=$(pg -d $db -c "select string_agg(note, ',' order by at) from drill_marker"); [ "$m" = "before,after-backup1" ] && ok "database markers in $db: $m" || no "$db markers: $m"; done
  c=$(nc -X PROPFIND -H 'Depth: 1' https://cloud.lab.test/remote.php/dav/files/root/ | grep -o 'nc-[ab][0-9].txt' | sort -u | wc -l); [ "$c" = "$NC_AT_GOOD" ] && ok "Nextcloud: $c files, as at T_GOOD (the one the damage deleted is back)" || no "Nextcloud: $c files, expected $NC_AT_GOOD"
  [ "$(nc https://cloud.lab.test/remote.php/dav/files/root/nc-b2.txt)" = "nextcloud file b2" ] && ok "Nextcloud: the deleted file's content is back" || no "Nextcloud: nc-b2.txt content"
  [ "$(curl -sk -u lab:$DAVPASS https://backup.lab.test/w-b1.txt)" = "webdav b1" ] && ok "WebDAV: the deleted file is back, with its content" || no "WebDAV: w-b1.txt"
  curl -sf http://127.0.0.1:8222/alive >/dev/null && ok "Vaultwarden answers on its restored database" || no "Vaultwarden"
  [ "$(sha256sum /var/lib/vaultwarden/rsa_key.pem | cut -d" " -f1)" = "$RSA_SUM" ] && ok "Vaultwarden: its RSA key (outside the database) is the one that was backed up" || no "Vaultwarden RSA key"
  incus start drill-ct </dev/null >/dev/null 2>&1; for i in $(seq 1 30); do incus exec drill-ct -- true </dev/null 2>/dev/null && break; sleep 2; done
  [ "$(incus exec drill-ct -- cat /root/marker </dev/null 2>&1)" = "incus-marker" ] && ok "Incus: the instance on the surviving 2 TB pool is back and its file is intact" || no "Incus instance"
  for r in /mnt/backup16/borg-everything /mnt/big2tb/borg-offsite; do BORG_REPO=$r borg check --verify-data >/dev/null 2>&1 && ok "borg check --verify-data: $r" || no "borg check: $r"; done
  runuser -u postgres -- pgbackrest --stanza=default check >/dev/null 2>&1 && ok "pgBackRest check: archiving works after the restore" || no "pgBackRest check"
  say "failed units: $(systemctl --failed --no-legend | wc -l)"
  [ $fail = 0 ] && echo "DRILL RESULT: PASS" || echo "DRILL RESULT: FAIL"
  ;;
esac
