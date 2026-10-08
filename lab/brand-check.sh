#!/usr/bin/env bash
# lab/brand-check.sh <vm-name> [screenshot dir] — the programs' pages of a lab VM running the host lab-brand, looked at by a headless browser (lab/brand-check.py), and the single sign-on
# from Immich through Nextcloud (lab/sso-check.py). Run lab/brand-test.sh first: it switches the VM to lab-brand.
# Needs a Playwright Python with a Chromium (PW_PYTHON, PW_CHROME; the defaults are the lab's) and ssh to the VM.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="${1:?usage: brand-check.sh <vm-name> [screenshot dir]}"; SHOTS="${2:-$(mktemp -d)}"
PW_PYTHON="${PW_PYTHON:-$HOME/lab/tidepool/pw-venv/bin/python}"
PW_CHROME="${PW_CHROME:-$(ls -d $HOME/.cache/ms-playwright/chromium-*/chrome-linux64/chrome | head -1)}"
port=$("$HERE/vm.sh" list | awk -v n="$NAME" '$1==n {sub("ssh:","",$3); print $3}')
for p in "$port" "$((port + 3))"; do ssh -n -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p "$p" lab@127.0.0.1 true 2>/dev/null && { port=$p; break; }; done
ssh -N -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -L 18443:10.100.0.1:443 -L 18444:127.0.0.1:443 -p "$port" lab@127.0.0.1 &
tunnel=$!; trap 'kill $tunnel 2>/dev/null' EXIT; sleep 3; kill -0 $tunnel 2>/dev/null || { echo "no tunnel (are the ports 18443 and 18444 free?)" >&2; exit 2; }
mkdir -p "$SHOTS"; "$PW_PYTHON" "$HERE/brand-check.py" "$PW_CHROME" "$SHOTS"; rc=$?
# the single sign-on, with a Nextcloud user made for the occasion
"$HERE/vm.sh" ssh "$NAME" 'sudo nextcloud-occ user:delete ssotest >/dev/null 2>&1; sudo env OC_PASS=SsoTest-pass-12345 nextcloud-occ user:add --password-from-env --display-name "SSO Test" ssotest >/dev/null && sudo nextcloud-occ user:setting ssotest settings email sso@example.test'
"$PW_PYTHON" "$HERE/sso-check.py" "$PW_CHROME" "$SHOTS" ssotest SsoTest-pass-12345 || rc=1
echo "screenshots: $SHOTS"; exit $rc
