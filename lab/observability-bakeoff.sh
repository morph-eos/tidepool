#!/usr/bin/env bash
# =============================================================================
# lab/observability-bakeoff.sh — the monitoring stack of ADR 0012 under real failures. Runs INSIDE the lab VM, as root, with modules/observability/stack.nix deployed. Lab scaffolding.
# Each case breaks something, and measures how long until a notification arrives by email and by push (ntfy), from the log of the sinks. Lab thresholds are shortened.
# =============================================================================
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH
say() { printf '  %s\n' "$*"; }
now() { date +%s; }
Q() { curl -s --data-urlencode "query=$1" localhost:9090/api/v1/query | jq -r '.data.result | length'; }
firing() { curl -s localhost:9090/api/v1/alerts | jq -r '[.data.alerts[] | select(.state=="firing") | .labels.alertname] | unique | join(",")'; }
mails() { grep -c . /tmp/lab-mail.log 2>/dev/null || echo 0; }
push() { curl -s "localhost:2586/alerts/json?poll=1&since=all" | grep -c '"event":"message"' ; }
wait_for() { # wait_for <seconds> <command...>: until the command succeeds
    local t=$1; shift; local s=$(now); while [ $(( $(now) - s )) -lt "$t" ]; do "$@" && { echo $(( $(now) - s )); return 0; }; sleep 3; done; echo "none in ${t}s"; return 1
}
: > /tmp/lab-mail.log; : > /tmp/lab-heartbeat.log
echo "== alerts under real failures"

# A1 the heartbeat
t=$(wait_for 180 sh -c '[ "$(grep -c . /tmp/lab-heartbeat.log)" -ge 2 ]'); say "A1 heartbeat (the always-firing Watchdog, repeated every minute to the dead-man's-switch address): $(grep -c . /tmp/lab-heartbeat.log) pings logged, the second after $t s"

# A2 a unit fails
m0=$(mails); t0=$(now); systemd-run --unit=boom-lab false >/dev/null 2>&1
t=$(wait_for 200 sh -c "[ \"\$(grep -c UnitFailed /tmp/lab-mail.log)\" -ge 1 ]"); say "A2 a systemd unit fails: the email for UnitFailed after $t s ($(grep UnitFailed /tmp/lab-mail.log | head -n 1 | cut -c1-110))"
systemctl reset-failed boom-lab.service 2>/dev/null

# A3 a service stops (critical: email and push)
p0=$(push); systemctl stop vaultwarden; t0=$(now)
t=$(wait_for 240 sh -c "[ \"\$(grep -c EndpointDown /tmp/lab-mail.log)\" -ge 1 ]"); say "A3 Vaultwarden stopped: email for EndpointDown after $t s"
t2=$(wait_for 60 sh -c "[ \"\$(curl -s 'localhost:2586/alerts/json?poll=1&since=all' | grep -c EndpointDown)\" -ge 1 ]"); say "A3 the push (ntfy) for the same alert after $t2 more s; message: $(curl -s 'localhost:2586/alerts/json?poll=1&since=all' | grep -m1 EndpointDown | jq -r '.title // .message' 2>/dev/null | cut -c1-90)"
systemctl start vaultwarden

# A4 certificate expiry (the test CA's certificates last 20 minutes)
say "A4 certificates close to expiry (lab threshold 15 min): firing now: $(firing)"
say "A4 expiry seen by the probes: $(curl -s --data-urlencode 'query=min(probe_ssl_earliest_cert_expiry{job="https"} - time())' localhost:9090/api/v1/query | jq -r '.data.result[0].value[1] // "none"' | cut -d. -f1) s left on the nearest"

# A5 the CAA record, asked of a public resolver
say "A5 the owner's CAA record as a public resolver answers: probe_success = $(curl -s --data-urlencode 'query=probe_success{job="caa"}' localhost:9090/api/v1/query | jq -r '.data.result[0].value[1] // "no data"') (1 = the record names letsencrypt.org; 0 = not visible yet or changed)"

# A6 a disk fills
mkdir -p /mnt/small; truncate -s 64M /tmp/small.img; mkfs.ext4 -q -F /tmp/small.img; mount -o loop /tmp/small.img /mnt/small; dd if=/dev/zero of=/mnt/small/fill bs=1M count=60 status=none 2>/dev/null; sync; t0=$(now)
t=$(wait_for 240 sh -c "[ \"\$(grep -c DiskAlmostFull /tmp/lab-mail.log)\" -ge 1 ]"); say "A6 a filesystem at 6% free: the email for DiskAlmostFull after $t s"
umount /mnt/small; rm -f /tmp/small.img

# A7 to A10 the metrics for the other cases exist
say "A7 memory pressure metric present: $(Q 'node_pressure_memory_waiting_seconds_total') series (rate now: $(curl -s --data-urlencode 'query=rate(node_pressure_memory_waiting_seconds_total[2m])' localhost:9090/api/v1/query | jq -r '.data.result[0].value[1]' | awk '{printf "%.5f", $1}'))"
say "A8 PostgreSQL archiver metric present: $(Q 'pg_stat_archiver_failed_count') series"
say "A9 systemd timers seen (the pattern for a backup that did not run): $(Q 'node_systemd_timer_last_trigger_seconds') timers"
say "A10 smartctl exporter on a virtual disk (no SMART): $(Q 'smartctl_device_smart_status') series for the SMART status; the exporter itself is $(systemctl is-active prometheus-smartctl-exporter)"

# A11 resources
echo "-- A11 memory in use (MiB)"
for u in prometheus alertmanager alertmanager-ntfy ntfy-sh grafana prometheus-node-exporter prometheus-postgres-exporter prometheus-blackbox-exporter prometheus-smartctl-exporter; do
    m=$(systemctl show $u -p MemoryCurrent --value 2>/dev/null); [ -n "$m" ] && [ "$m" != "[not set]" ] && printf '    %-34s %5d\n' "$u" $(( m / 1048576 ))
done
echo "-- A12 Grafana"
say "health: $(curl -s localhost:3000/api/health | jq -c '{database,version}'); datasource provisioned: $(curl -s -u admin:lab-only-grafana-admin localhost:3000/api/datasources | jq -r '.[].name' | paste -sd,)"
say "mails received in total: $(mails); push messages: $(push)"
