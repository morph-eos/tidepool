#!/usr/bin/env bash
# =============================================================================
# lab/smoke-test.sh — the lab host, switched to the flake as it is in this working tree, comes up whole
#
# Usage: lab/smoke-test.sh <vm-name>     (a NixOS lab VM; it is switched to the host `lab`)
# Checks: nothing failed, every name answers as it should (and an unknown one does not answer at all), Immich runs on its declared settings, Prometheus is ready, the operating system carries the brand's name.
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
sudo nixos-rebuild test --flake path:$PWD#lab 2>&1 | tail -n 1
sudo systemctl restart 'acme-order-renew-*.service' nginx; sleep 40
code() { curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$1:443:127.0.0.1" "https://$1/$2"; }
D=lab.test
r "cloud answers (a redirect to its login)"           302 code cloud.$D
r "vault answers"                                    200 code vault.$D alive
r "photos answers"                                   200 code photos.$D api/server/ping
r "push answers"                                     200 code push.$D
r "backup asks for a password"                       401 code backup.$D
r "a name that is nobody's gets no answer"           000 code nobody.$D
r "Immich runs on its declared settings"             "https://photos.$D" bash -c "curl -s localhost:2283/api/server/config | jq -r .externalDomain"
r "Prometheus is ready"                              "Prometheus Server is Ready." bash -c "curl -s localhost:9090/-/ready | tr -d '\n'"
r "the operating system carries the brand's name"    "NAME=Tidepool" grep -E '^NAME=' /etc/os-release
r "the database answers"                             "1" bash -c "sudo -u postgres psql -tAc 'select 1'"
# the lab's test CA can refuse an order that comes in the same second as its start: an ACME order that failed is tried once more, any other unit is reported as it is
for u in $(systemctl --failed --no-legend | sed 's/^[^a-zA-Z]*//' | cut -d' ' -f1 | grep '^acme-order-renew-'); do sudo systemctl reset-failed "$u"; sudo systemctl restart "$u"; done; sleep 5
systemctl --failed --no-legend | sed 's/^[^a-zA-Z]*//' | cut -d" " -f1 | sed 's/^/failed unit: /'
echo "failed units: $(systemctl --failed --no-legend | wc -l)"
REMOTE_EOF
