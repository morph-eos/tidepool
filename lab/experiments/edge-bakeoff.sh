#!/usr/bin/env bash
# =============================================================================
# lab/experiments/edge-bakeoff.sh — the edge candidates under the same checks (ADR 0008). Runs INSIDE the lab VM, as root, right after the candidate is deployed
# (the certificate timing is measured from that moment). Needs the fixtures of nixos/modules/edge/common.nix. Lab scaffolding, not part of the system.
#
#   E1  certificates: how long until every name serves a certificate from the test CA
#   E2  TLS: which protocol versions are offered
#   E3  HTTP is redirected to HTTPS; E4 security headers
#   E5  the real client IP reaches the backend (the client uses another loopback address)
#   E6  WebSocket   E7  a 3 GB upload   E8  an answer after 75 s   E9  a missing backend, and the others   E10 HTML injection   E11 mTLS passthrough
#
# Usage:  sudo bash edge-bakeoff.sh <candidate-label> [E-number ...]
# =============================================================================
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH
CAND=${1:?label}; shift || true
ONLY=("$@")
want() { [ ${#ONLY[@]} -eq 0 ] && return 0; local x; for x in "${ONLY[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }
MT=/etc/edge-lab/mtls
say() { printf '  %s\n' "$*"; }
now() { date +%s.%N; }
el() { awk -v a="$1" -v b="$(now)" 'BEGIN{printf "%.1f", b-a}'; }
NAMES=$(grep -oE '[a-z]+\.(lab|alt)\.test' /etc/hosts | sort -u | grep -v '^incus\.')
NN=$(echo "$NAMES" | wc -l)
echo "== edge candidate: $CAND ($NN names)"

# ---------------------------------------------------------------- E1
if want E1; then
    t0=$(now); ok=0
    for i in $(seq 1 120); do
        ok=0
        for n in $NAMES; do
            iss=$(echo | timeout 5 openssl s_client -connect 127.0.0.1:443 -servername "$n" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)
            case "$iss" in *Pebble*) ok=$((ok + 1));; esac
        done
        [ "$ok" -eq "$NN" ] && break
        sleep 2
    done
    say "E1: $ok of $NN names serve a certificate from the test CA after $(el "$t0") s (measured from the start of this script)"
fi
curl -s --cacert /etc/ssl/certs/ca-certificates.crt https://localhost:15000/roots/0 > /tmp/pebble-root.pem 2>/dev/null
curl -s --cacert /etc/ssl/certs/ca-certificates.crt https://localhost:15000/intermediates/0 >> /tmp/pebble-root.pem 2>/dev/null
CURL="curl -s --cacert /tmp/pebble-root.pem"

# ---------------------------------------------------------------- E2
if want E2; then
    out=$(testssl.sh --quiet --color 0 --protocols plain.lab.test:443 2>&1 | grep -E "^ ?(SSLv|TLS 1)" | sed 's/  */ /g' | tr '\n' ';')
    say "E2: protocols: ${out:-testssl gave no answer}"
fi

# ---------------------------------------------------------------- E3, E4
if want E3; then
    r=$(curl -s -o /dev/null -w "%{http_code} -> %{redirect_url}" http://plain.lab.test/)
    say "E3: http://plain.lab.test/ gives $r"
fi
if want E4; then
    h=$($CURL -sI https://plain.lab.test/ | tr -d '\r')
    for k in strict-transport-security x-content-type-options x-frame-options; do
        v=$(echo "$h" | grep -i "^$k:" | head -n 1 | cut -c1-80); say "E4: ${v:-$k: MISSING}"
    done
    say "E4: HTTP version: $($CURL -o /dev/null -w '%{http_version}' https://plain.lab.test/)"
fi

# ---------------------------------------------------------------- E5
if want E5; then
    j=$($CURL --interface 127.0.0.2 https://plain.lab.test/)
    say "E5: the backend saw x-forwarded-for=$(echo "$j" | jq -r '."x-forwarded-for" // "none"'), x-real-ip=$(echo "$j" | jq -r '."x-real-ip" // "none"') for a client at 127.0.0.2"
fi

# ---------------------------------------------------------------- E6
if want E6; then
    r=$(echo hello | timeout 15 websocat -k -n1 wss://ws.lab.test/ 2>&1 | head -n 1)
    say "E6: WebSocket echo: ${r:-no answer}"
fi

# ---------------------------------------------------------------- E7
if want E7; then
    truncate -s 3G /tmp/up3g.bin
    t0=$(now); r=$($CURL -T /tmp/up3g.bin -H 'Content-Type: application/octet-stream' -w ' http=%{http_code}' https://up.lab.test/ 2>&1 | tail -c 120)   # -T streams the file; --data-binary would read all 3 GB into memory
    say "E7: 3 GB upload in $(el "$t0") s: $r (3221225472 bytes sent)"; rm -f /tmp/up3g.bin
fi

# ---------------------------------------------------------------- E8
if want E8; then
    t0=$(now); r=$($CURL --max-time 150 -w ' http=%{http_code}' https://slow.lab.test/ 2>&1 | tail -c 80)
    say "E8: a backend that answers after 75 s: $r after $(el "$t0") s"
fi

# ---------------------------------------------------------------- E9
if want E9; then
    c1=$($CURL -o /dev/null -w '%{http_code}' https://down.lab.test/)
    c2=$($CURL -o /dev/null -w '%{http_code}' https://plain.lab.test/)
    say "E9: the missing backend answers $c1, another name answers $c2"
fi

# ---------------------------------------------------------------- E10
if want E10; then
    r=$($CURL https://inj.lab.test/ | grep -c 'sso.js')
    say "E10: HTML injection: $([ "$r" -ge 1 ] && echo 'the script tag is in the page' || echo 'NOT INJECTED')"
fi

# ---------------------------------------------------------------- E11
if want E11; then
    a=$(curl -s --cacert $MT/ca.pem --cert $MT/client.pem --key $MT/client.key https://incus.lab.test/ 2>&1 | head -c 120)
    b=$(curl -s --cacert $MT/ca.pem https://incus.lab.test/ 2>&1 | head -c 100; echo " (curl exit $?)")
    say "E11: with the client certificate: ${a:-no answer}"
    say "E11: without it: ${b}"
fi

# ---------------------------------------------------------------- E12 (nginx and any candidate with a renewal we can trigger: set validMinDays high in the lab)
if want E12; then
    ser() { echo | timeout 5 openssl s_client -connect 127.0.0.1:443 -servername "$1" 2>/dev/null | openssl x509 -noout -serial; }
    before=$(ser slow.lab.test)
    ( $CURL --max-time 130 -o /tmp/e12.out -w '%{http_code}' https://slow.lab.test/ > /tmp/e12.code 2>&1 ) &
    BG=$!
    sleep 5
    # lego renews at one third of the lifetime and the test CA's certificates last years, so a re-issue is forced: the stored domain list is altered and the module's own order unit runs
    echo tampered > /var/lib/acme/.lego/slow.lab.test/*/domainhash.txt
    systemctl start acme-order-renew-slow.lab.test.service
    sleep 3
    after=$(ser slow.lab.test)
    wait $BG
    say "E12: certificate serial before: ${before#serial=}, after the renewal: ${after#serial=}; the 75 s request that was open during the renewal ended with http=$(cat /tmp/e12.code), body $(cat /tmp/e12.out)"
fi

# ---------------------------------------------------------------- E13
if want E13; then
    NG=$(grep -oE '/nix/store/[a-z0-9]+-nginx-[0-9.]+/bin/nginx' /etc/systemd/system/nginx.service | head -n 1)
    cat > /tmp/bad.conf <<'CONF'
events {}
http { server { listen 127.0.0.1:18080; location / { proxy_pass http://no-such-host.invalid:80; } } }
CONF
    r=$($NG -t -c /tmp/bad.conf 2>&1 | head -n 2 | tr '\n' ' ')
    say "E13: a literal upstream name that does not resolve: ${r}"
fi
