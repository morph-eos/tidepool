#!/usr/bin/env bash
# Writes the Wi-Fi key into secrets.yaml: the 64 hex digits that wpa_passphrase would print for the network in host.nix. The passphrase is asked here, never kept.
set -euo pipefail
cd "$(dirname "$0")/.."
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/tidepool/age.key}"
SOPS="${SOPS:-sops}"
ssid=$(sed -n 's/.*ssid = "\([^"]*\)".*/\1/p' host.nix | head -1)
[ -n "$ssid" ] || { echo "no ssid in host.nix" >&2; exit 1; }
read -rsp "Wi-Fi passphrase of '$ssid': " pass; echo
psk=$(python3 -c 'import hashlib,sys; print(hashlib.pbkdf2_hmac("sha1", sys.argv[1].encode(), sys.argv[2].encode(), 4096, 32).hex())' "$pass" "$ssid")
$SOPS set secrets.yaml '["wifi-psk"]' "\"psk_home=$psk\"" && echo "wifi-psk set"
