#!/usr/bin/env bash
# =============================================================================
# lab/experiments/push-public-u13.sh — ADR 0017: push notifications WITHOUT the VPN (ntfy on the public side, behind nginx), tried in the lab host.
# Runs INSIDE the lab host as root; /home/lab/nixos is the flake with tidepool.push.enable and the two logins in the lab secrets file.
# $PHONE_PW and $BRIDGE_PW (the lab logins) are in the environment.
# =============================================================================
set -uo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH
export NIX_CONFIG='experimental-features = nix-command flakes
download-attempts = 60'
ms() { echo $(( $(date +%s%N) / 1000000 )); }
say() { echo "$(date +%H:%M:%S) $*"; }
say "== deploy"
nixos-rebuild test --flake path:/home/lab/nixos#lab 2>&1 | grep -E "error|Done" | head -n 3 | cut -c1-160; sleep 12
say "failed units: $(systemctl --failed --no-legend | tr -s ' ' | cut -d' ' -f2 | tr '\n' ' ')"
N="curl -sk -m 8 --resolve push.lab.test:443:10.0.2.15"
U=https://push.lab.test
code() { $N -o /dev/null -w '%{http_code}' "$@"; }
say "== what a stranger sees from the LAN/public address (no login)"
say "GET /                       -> $(code $U/)   (the web page itself)"
say "GET /v1/health              -> $(code $U/v1/health)"
say "GET /alerts/json?poll=1     -> $(code "$U/alerts/json?poll=1")   (read the topic)"
say "POST /alerts                -> $(code -d x $U/alerts)   (write the topic)"
say "GET /<a guessed topic>/json -> $(code "$U/backup/json?poll=1")   (topics are closed by default, whatever the name)"
say "== the two logins"
say "phone reads alerts          -> $(code -u phone:$PHONE_PW "$U/alerts/json?poll=1")"
say "phone writes alerts         -> $(code -u phone:$PHONE_PW -d x $U/alerts)   (read-only)"
say "bridge writes alerts        -> $(code -u bridge:$BRIDGE_PW -d "bridge test" $U/alerts)"
say "bridge reads alerts         -> $(code -u bridge:$BRIDGE_PW "$U/alerts/json?poll=1")   (write-only)"
say "phone reads another topic   -> $(code -u phone:$PHONE_PW "$U/other/json?poll=1")"
say "== guessing the login: 60 wrong passwords in a row, status codes seen"
for i in $(seq 1 60); do code -u phone:wrong$i "$U/alerts/json?poll=1"; echo; done | sort | uniq -c | tr '\n' ';'; echo
say "after that, the right login: $(code -u phone:$PHONE_PW "$U/alerts/json?poll=1")   (an address locked by repeated failures would show 429 here)"
say "== nginx limit_req: 200 requests in a burst (no login), status codes"
for i in $(seq 1 200); do $N -o /dev/null -w '%{http_code}\n' $U/v1/health & done | sort | uniq -c | tr '\n' ';'; wait; echo
say "== an alert end to end: a critical alert -> Alertmanager -> mail AND push (the phone login reads it)"
sudo rm -f /tmp/lab-mail.log; t0=$(ms)
curl -s -XPOST localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[{"labels":{"alertname":"LabPushTest","severity":"critical","instance":"lab"},"annotations":{"summary":"push test"}}]' >/dev/null
for i in $(seq 1 40); do n=$($N -u phone:$PHONE_PW "$U/alerts/json?poll=1&since=all" | grep -c LabPushTest); m=$(grep -c "FIRING" /tmp/lab-mail.log 2>/dev/null || echo 0); [ "$n" -gt 0 ] && [ "$m" -gt 0 ] && break; sleep 2; done
say "push seen on the topic: $n, mail seen in the sink: $m, after $(( ($(ms) - t0) / 1000 )) s"
say "== a live subscription through nginx (websocket-free JSON stream), a message posted while it is open"
( timeout 12 $N -u phone:$PHONE_PW -N "$U/alerts/json" > /tmp/stream.out 2>&1 & )
sleep 3; t1=$(ms); $N -u bridge:$BRIDGE_PW -d "live message" $U/alerts >/dev/null; sleep 3
say "the open stream received it: $(grep -c 'live message' /tmp/stream.out); the stream was held open through nginx for 12 s: $(grep -c '"event":"keepalive"' /tmp/stream.out) keepalive(s)"
say "== what leaves for ntfy.sh when upstream-base-url is set (a second throw-away ntfy, and a listener standing in for ntfy.sh)"
mkdir -p /tmp/up && cd /tmp/up
cat > srv.py <<'P'
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n=int(self.headers.get('Content-Length',0)); body=self.rfile.read(n)
        open('/tmp/up/got.log','a').write(f"{self.command} {self.path} headers={dict(self.headers)} body={body!r}\n"); self.send_response(200); self.end_headers()
    do_GET=do_POST; do_PUT=do_POST
    def log_message(self,*a): pass
http.server.HTTPServer(('127.0.0.1',9999),H).serve_forever()
P
rm -f got.log; python3 srv.py & SP=$!
cat > n2.yml <<'P'
listen-http: "127.0.0.1:2587"
base-url: "http://ntfy2.example"
upstream-base-url: "http://127.0.0.1:9999"
cache-file: "/tmp/up/cache.db"
P
ntfy serve --config n2.yml >/tmp/up/n2.log 2>&1 & NP=$!
sleep 3
curl -s -m 5 -d "SECRET TEXT: the backup failed on host X" http://127.0.0.1:2587/my-private-topic >/dev/null; sleep 2
say "requests the upstream received: $(wc -l < got.log 2>/dev/null || echo 0)"; sed -E 's/headers=.*body=/body=/' got.log 2>/dev/null | head -n 3
say "does the text appear in what was sent upstream? $(grep -c 'SECRET TEXT' got.log 2>/dev/null); does the topic name? $(grep -c 'my-private-topic' got.log 2>/dev/null)"
kill $SP $NP 2>/dev/null; cd /
say "== cost"
say "memory: ntfy-sh $(systemctl show ntfy-sh -p MemoryCurrent --value | awk '{printf "%d", $1/1048576}') MiB, alertmanager-ntfy $(systemctl show alertmanager-ntfy -p MemoryCurrent --value | awk '{printf "%d", $1/1048576}') MiB; listening sockets of the whole host that are not loopback: $(ss -tlnH | awk '$4 !~ /^127\.|^\[::1\]/ {print $4}' | sort -u | tr '\n' ' ')"
say done
