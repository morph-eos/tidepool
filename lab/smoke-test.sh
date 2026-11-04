#!/usr/bin/env bash
# =============================================================================
# lab/smoke-test.sh — the lab host, switched to the flake as it is in this working tree, comes up whole
#
# Usage: lab/smoke-test.sh <vm-name>     (a NixOS lab VM; it is switched to the host `lab`)
# Checks: nothing failed, the Borg jobs carry what they should, the database dump restores and its unit leaves its last success, every name answers as it should (and an unknown one does not answer at all), Immich runs on its declared settings, Prometheus is ready, the operating system carries the brand's name.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="${1:?usage: smoke-test.sh <vm-name>}"
tar -C "$HERE/.." -c nixos | "$HERE/vm.sh" ssh "$NAME" 'rm -rf ~/nn && mkdir ~/nn && tar x -C ~/nn'
"$HERE/vm.sh" ssh "$NAME" 'bash -s' <<'REMOTE_EOF'
r() { local desc="$1" want="$2"; shift 2; local got; got=$("$@" 2>/dev/null); if [ "$got" = "$want" ]; then echo "PASS $desc"; else echo "FAIL $desc (wanted '$want', got '$got')"; fi; }
cd ~/nn/nixos
# the lab's test CA forgets its accounts at every start: the ones saved by the last run are cleared
sudo rm -rf /var/lib/acme/.lego/accounts; sudo systemctl reset-failed
sudo nixos-rebuild test --flake path:$PWD#lab > /tmp/switch.log 2>&1; rc=$?; tail -n 1 /tmp/switch.log; [ $rc -eq 0 ] || { echo "FAIL the switch to the host lab failed (exit $rc): $(grep -m1 -i 'error' /tmp/switch.log | cut -c1-160)"; }
sudo systemctl restart 'acme-order-renew-*.service' nginx; sleep 40
code() { curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$1:443:127.0.0.1" "https://$1/$2"; }
D=lab.test
r "cloud answers (a redirect to its login)"           302 code cloud.$D
r "vault answers"                                    200 code vault.$D alive
r "photos answers"                                   200 code photos.$D api/server/ping
r "push answers"                                     200 code push.$D
r "backup asks for a password"                       401 code backup.$D
r "a name that is nobody's gets no answer"           000 code nobody.$D
r "the vault's admin panel is not served"                404 code vault.$D admin
r "Immich runs on its declared settings"             "https://photos.$D" bash -c "curl -s localhost:2283/api/server/config | jq -r .externalDomain"
r "Prometheus is ready"                              "Prometheus Server is Ready." bash -c "curl -s localhost:9090/-/ready | tr -d '\n'"
r "the admin page answers on the VPN address"       200 curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve admin.$D:443:10.100.0.1 https://admin.$D/
r "the operating system carries the brand's name"    "NAME=Tidepool" grep -E '^NAME=' /etc/os-release
r "the database answers"                             "1" bash -c "sudo -u postgres psql -tAc 'select 1'"
# the dump that both Borg repositories carry: made by its unit, and readable as a PostgreSQL archive
sudo systemctl start tidepool-db-dump.service
# Immich's own database role: not a superuser, owns what it uses, and root reaches nothing else through the peer map
r "Immich's database role is not a superuser"      f bash -c "sudo -u postgres psql -tAc \"select rolsuper from pg_roles where rolname = 'immich'\""
r "nothing of Immich's own is left to postgres" 0 bash -c "sudo -u postgres psql -d immich -tAc \"select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and pg_get_userbyid(c.relowner) = 'postgres' and c.relkind in ('r','S','v','m') and not exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype = 'e')\" | tr -d ' '"
r "Immich's role reads its own database"            1 sudo psql -h /run/postgresql -U immich -d immich -tAc 'select 1'
r "Immich's role is refused the other databases"   refused bash -c "sudo psql -h /run/postgresql -U immich -d vaultwarden -tAc 'select 1' >/dev/null 2>&1 && echo open || echo refused"
r "root cannot become postgres through the map"    refused bash -c "sudo psql -h /run/postgresql -U postgres -d immich -tAc 'select 1' >/dev/null 2>&1 && echo open || echo refused"
r "the vault database is dumped for the Borg repositories" PGDMP sudo head -c 5 /var/lib/tidepool-db-dumps/vaultwarden.dump
# a dump that cannot be restored is no backup: it is restored into an empty database, and the tables and their rows must be those of the database it came from
rows_sql='select table_schema||$$.$$||table_name||$$ $$||(xpath($$/row/c/text()$$, query_to_xml(format($$select count(*) as c from %I.%I$$, table_schema, table_name), false, true, $$$$)))[1]::text from information_schema.tables where table_type=$$BASE TABLE$$ and table_schema not in ($$pg_catalog$$,$$information_schema$$) order by 1'
rows() { sudo -u postgres psql -Atq -d "$1" -c "$rows_sql"; }
restore_matches() {
  sudo -u postgres dropdb --if-exists smoke_restore && sudo -u postgres createdb smoke_restore || return
  sudo -u postgres pg_restore --exit-on-error --dbname=smoke_restore /var/lib/tidepool-db-dumps/vaultwarden.dump || { echo "pg_restore failed"; return; }
  if [ "$(rows smoke_restore | wc -l)" -gt 0 ] && [ "$(rows smoke_restore)" = "$(rows vaultwarden)" ]; then echo same; else echo different; fi
}
r "the vault dump restores into an empty database, tables and rows as in the original" same restore_matches
sudo -u postgres dropdb --if-exists smoke_restore
# /etc is a net for changes made by hand: the Borg job of everything reads it, the offsite one does not (the jobs' scripts are read, not run: the lab has no backup disks)
job_paths() { local start; start=$(systemctl show "borgbackup-job-$1.service" -p ExecStart --value | grep -o -E 'path=[^ ;]*' | head -1 | cut -d= -f2); sudo grep -c -E '(^|[[:space:]])/etc([[:space:]\\]|$)' "$(grep -o -E '/nix/store/[^ ]*borgbackup-job-[a-z]*-script' "$start" | head -1)"; }
r "the Borg job of everything reads /etc" 1 job_paths everything
r "and the offsite one does not" 0 job_paths offsite
# a backup unit that ended well leaves the time of it (BackupNoRecentSuccess), and says how old that may get
last_success_age() { curl -s localhost:9100/metrics | awk -v now="$(date +%s)" '/^tidepool_backup_last_success_timestamp_seconds\{unit="tidepool-db-dump"\}/ { print (now - $2 < 300 ? "recent" : "old") }'; }
r "the dump unit leaves the time of its last success" recent last_success_age
r "and the age it may reach" 1 bash -c "curl -s localhost:9100/metrics | grep -c '^tidepool_backup_max_age_seconds{unit=\"tidepool-db-dump\"}'"
r "the versions' metrics are still read from the same directory" 1 bash -c "curl -s localhost:9100/metrics | grep -c '^tidepool_deployed_info{app=\"nextcloud\"'"
# a service that fails tells Alertmanager at once (the drop-in for every service posts the alert), with the time it failed, and the alert's own unit does not start another.
# The unit's name is new at every run: an alert of the same name from an earlier run stays firing for two hours and keeps its first start, and Alertmanager groups by alert name, so a second mail would wait for the group interval
u=smoke-fail-$(date +%s); sudo systemd-run --quiet --unit=$u /bin/sh -c 'exit 3'; sleep 15
r "a service that fails is in Alertmanager at once, with its start time" yes bash -c "curl -s localhost:9093/api/v2/alerts | jq -e --arg u $u.service '[.[] | select(.labels.alertname == \"ServiceFailed\" and .labels.unit == \$u) | (.startsAt[:19] + \"Z\" | fromdateiso8601) | select(. > now - 120 and . < now + 5)] | length == 1' >/dev/null && echo yes"
r "the alert's own unit has no alert of its own" "OnFailure=" bash -c "systemctl show tidepool-alert@x.service -p OnFailure | tr -d '\n'"
sudo systemctl reset-failed $u.service 2>/dev/null
# the lab's test CA can refuse an order that comes in the same second as its start: an ACME order that failed is tried once more, any other unit is reported as it is
for u in $(systemctl --failed --no-legend | sed 's/^[^a-zA-Z]*//' | cut -d' ' -f1 | grep '^acme-order-renew-'); do sudo systemctl reset-failed "$u"; sudo systemctl restart "$u"; done; sleep 5
systemctl --failed --no-legend | sed 's/^[^a-zA-Z]*//' | cut -d" " -f1 | sed 's/^/failed unit: /'
echo "failed units: $(systemctl --failed --no-legend | wc -l)"
REMOTE_EOF
