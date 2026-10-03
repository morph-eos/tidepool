#!/usr/bin/env bash
# =============================================================================
# lab/updates-u2.sh <days> — phase 8 (ADR 0016), U2: what a real update does to the services while it is applied. Runs INSIDE the lab host as root, after updates-u1.sh has built
# /root/u1out/old-<days> and /root/u1out/new-<days>. It puts the host on the OLD system, then switches to the NEW one while a probe asks every service every 0.2 s,
# and reports the units that were restarted and the longest silence of each service.
# =============================================================================
set -uo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH
D=${1:?days}; OUT=/root/u1out
say() { echo "$(date +%H:%M:%S) $*"; }
probe() { # probe <name> <command...>: prints "t_ms up|down" on every change, until /tmp/probe.stop exists
  local n=$1; shift; local last=""; while [ ! -e /tmp/probe.stop ]; do
    if "$@" >/dev/null 2>&1; then c=up; else c=down; fi
    [ "$c" != "$last" ] && echo "$(( $(date +%s%N) / 1000000 )) $n $c" >> /tmp/probe.log; last=$c; sleep 0.2
  done; }
curlok() { curl -sk -m 2 -o /dev/null -w '%{http_code}' --resolve "$1:443:127.0.0.1" "https://$1$2" | grep -qE "^(200|301|302|401)$"; }
say "== putting the host on the OLD system ($D days old nixpkgs)"
$OUT/old-$D/bin/switch-to-configuration test 2>&1 | grep -E "restarting|starting|stopping|the following" | cut -c1-200 | head -n 8
sleep 20
rm -f /tmp/probe.stop /tmp/probe.log
probe vaultwarden curlok vault.lab.test /alive & probe nextcloud curlok cloud.lab.test /status.php & probe immich curlok photos.lab.test /api/server/ping & probe webdav curlok dav.lab.test / &
probe postgres pg_isready -q -h /run/postgresql &
sleep 3; t0=$(( $(date +%s%N) / 1000000 ))
say "== THE UPDATE: switching to the NEW system"
s=$(date +%s); $OUT/new-$D/bin/switch-to-configuration test 2>&1 | grep -E "restarting|starting|stopping|reloading|the following|warning|error" | cut -c1-230 | head -n 16
say "switch took $(( $(date +%s) - s )) s"; sleep 25; touch /tmp/probe.stop; sleep 1; wait
say "== silences seen by the probe (each line: how long the service did not answer, counted from the first failure to the next success)"
python3 - "$t0" <<'PY' 2>/dev/null || awk -v t0="$t0" 'BEGIN{} {print}' /tmp/probe.log
import sys,collections
t0=int(sys.argv[1]); ev=collections.defaultdict(list)
for l in open("/tmp/probe.log"):
    t,n,c=l.split(); ev[n].append((int(t),c))
for n,e in ev.items():
    outs=[];d=None
    for t,c in e:
        if c=="down" and d is None: d=t
        if c=="up" and d is not None: outs.append(t-d); d=None
    if d is not None: outs.append(-1)
    print(f"  {n:12s} silences: {[f'{o/1000:.1f} s' if o>=0 else 'still down' for o in outs] or 'none'}")
PY
say done
