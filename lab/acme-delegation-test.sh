#!/usr/bin/env bash
# =============================================================================
# lab/acme-delegation-test.sh — ADR 0008, route 1: a certificate for test.<domain> by the DNS challenge, the challenge name delegated by CNAME to acme-dns, against Let's Encrypt STAGING.
# Runs on the WORKSTATION. Needs, outside the repository, in ~/lab/tidepool/secrets/: `domain` (one line) and `acmedns-register.json` (the answer of acme-dns's /register).
# The owner must already have added at the DNS provider:  _acme-challenge.test.<domain>  CNAME  <fulldomain from the registration>
# =============================================================================
set -uo pipefail
S=~/lab/tidepool/secrets; REPO=${REPO:-~/Codice/nas-scripts-history-clean}; WT=${WT:-~/lab/tidepool/wt-edge}
[ -s "$S/domain" ] && [ -s "$S/acmedns-register.json" ] || { echo "missing $S/domain or $S/acmedns-register.json"; exit 1; }
DOMAIN=$(tr -d '\n' < "$S/domain"); NAME="test.$DOMAIN"
mkdir -p "$WT/nixos/private"; printf '%s' "$DOMAIN" > "$WT/nixos/private/domain"
python3 - "$S/acmedns-register.json" "$NAME" "$S/acme-dns-storage.json" <<'PYEND'
import json, sys
reg = json.load(open(sys.argv[1])); name = sys.argv[2]
json.dump({name: reg}, open(sys.argv[3], "w"))
PYEND
echo "ACME_DNS_API_BASE=https://auth.acme-dns.io" > "$S/acme-dns.env"
echo "ACME_DNS_STORAGE_PATH=/var/lib/acme-private/storage.json" >> "$S/acme-dns.env"
FULL=$(python3 -c "import json;print(json.load(open('$S/acmedns-register.json'))['fulldomain'])")
echo "== is the CNAME in place? (_acme-challenge.test.<domain> -> $FULL)"
getent ahosts "_acme-challenge.$NAME" >/dev/null 2>&1; dig +short CNAME "_acme-challenge.$NAME" 2>/dev/null | head -n 2 || true
cd "$REPO"
# secrets to the lab VM only (root-only files)
cat "$S/acme-dns.env" | lab/vm.sh ssh host-n 'sudo install -d -m 700 /root/secrets; sudo tee /root/secrets/acme-dns.env >/dev/null; sudo chmod 600 /root/secrets/acme-dns.env'
cat "$S/acme-dns-storage.json" | lab/vm.sh ssh host-n 'sudo install -d -m 700 /var/lib/acme-private; sudo tee /var/lib/acme-private/storage.json >/dev/null; sudo chmod 600 /var/lib/acme-private/storage.json'
tar -C "$WT" -cf - nixos | lab/vm.sh ssh host-n 'rm -rf ~/nixos && tar -C ~ -xf - && sudo systemd-run --unit=acmedeleg --collect --property=StandardOutput=file:/tmp/acmedeleg.log --property=StandardError=file:/tmp/acmedeleg.log -E PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin bash -c "cd /home/lab && nixos-rebuild switch --option download-attempts 60 --flake path:/home/lab/nixos#tidepool-lab; echo exit=\$?" | tail -n 1'
