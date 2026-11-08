#!/usr/bin/env bash
# =============================================================================
# lab/brand-alt.sh — a brand of another repository, on a running lab VM: the VM is switched to the host lab-pippo (the host lab-brand with a brand that names everything in its own words, nixos/brand/test/pippo-brand.json),
# and a browser looks at every program that takes a brand (lab/brand-alt.py): the title of each page, the footer, the sign-in button, the logo and the palette must be Pippo's and no trace of the default brand is left.
#
# Usage: lab/brand-alt.sh <vm-name> [screenshot dir]      (switches the VM; run lab/brand-test.sh first to put it back on lab-brand)
# Needs a Playwright Python with a Chromium (PW_PYTHON, PW_CHROME; the defaults are the lab's) and ssh to the VM.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="${1:?usage: brand-alt.sh <vm-name> [screenshot dir]}"; SHOTS="${2:-$(mktemp -d)}"
PW_PYTHON="${PW_PYTHON:-$HOME/lab/tidepool/pw-venv/bin/python}"
PW_CHROME="${PW_CHROME:-$(ls -d $HOME/.cache/ms-playwright/chromium-*/chrome-linux64/chrome 2>/dev/null | head -1)}"; [ -x "$PW_CHROME" ] || PW_CHROME=/usr/bin/google-chrome
tar -C "$HERE/.." -c nixos | "$HERE/vm.sh" ssh "$NAME" 'rm -rf ~/nn && mkdir ~/nn && tar x -C ~/nn'
"$HERE/vm.sh" ssh "$NAME" 'bash -s' <<'REMOTE_EOF'
cd ~/nn/nixos
sudo rm -rf /var/lib/acme/.lego/accounts; sudo systemctl reset-failed
sudo nixos-rebuild test --flake path:$PWD#lab-pippo > /tmp/switch.log 2>&1; rc=$?; tail -n 1 /tmp/switch.log; [ $rc -eq 0 ] || echo "FAIL the switch to the host lab-pippo failed (exit $rc): $(grep -m1 -i 'error' /tmp/switch.log | cut -c1-160)"
sudo systemctl restart "acme-order-renew-*.service" nginx; sleep 10
sudo systemctl restart podman-jellyfin.service; for i in $(seq 1 40); do curl -s localhost:8096/System/Info/Public | grep -q '"ServerName"' && break; sleep 3; done   # the server's name is set at the start after the first
sudo systemctl restart podman-floppy.service homepage-dashboard.service; sleep 25
REMOTE_EOF
port=$("$HERE/vm.sh" list | awk -v n="$NAME" '$1==n {sub("ssh:","",$3); print $3}')
for p in "$port" "$((port + 3))"; do ssh -n -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p "$p" lab@127.0.0.1 true 2>/dev/null && { port=$p; break; }; done
ssh -N -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -L 18443:10.100.0.1:443 -L 18444:127.0.0.1:443 -p "$port" lab@127.0.0.1 &
tunnel=$!; trap 'kill $tunnel 2>/dev/null' EXIT; sleep 3; kill -0 $tunnel 2>/dev/null || { echo "no tunnel (are the ports 18443 and 18444 free?)" >&2; exit 2; }
mkdir -p "$SHOTS"; "$PW_PYTHON" "$HERE/brand-alt.py" "$PW_CHROME" "$SHOTS"; rc=$?
echo "screenshots: $SHOTS"; exit $rc
