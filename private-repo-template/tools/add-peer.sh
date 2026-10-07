#!/usr/bin/env bash
# Adds a VPN device (ENDPOINT=<dynamic-DNS name>:51820 if it is not the default below): makes its key pair, appends it to vpn-peers.nix and prints the client's WireGuard configuration (the private key is shown ONCE here and kept nowhere).
# Usage: tools/add-peer.sh <name> <last byte of the address, 2..254>      e.g. tools/add-peer.sh phone 2
set -euo pipefail
cd "$(dirname "$0")/.."
name=${1:?usage: add-peer.sh <name> <n>}; n=${2:?usage: add-peer.sh <name> <n>}
endpoint=${ENDPOINT:-vpn.example.org:51820}
grep -q "10.100.0.$n/32" vpn-peers.nix && { echo "10.100.0.$n is taken" >&2; exit 1; }
priv=$(wg genkey); pub=$(printf '%s' "$priv" | wg pubkey)
python3 - "$name" "$n" "$pub" <<'PY'
import re, sys
name, n, pub = sys.argv[1:]
s = open("vpn-peers.nix").read().rstrip()
entry = f'  {{ publicKey = "{pub}"; allowedIPs = [ "10.100.0.{n}/32" ]; }}   # {name}\n'
if s.startswith("[ ]"): s = "[\n" + entry + "]\n"
else: s = s.rstrip("]").rstrip() + "\n" + entry + "]\n"
open("vpn-peers.nix", "w").write(s)
PY
cat <<CONF

# ---- $name (shown once) ----
[Interface]
PrivateKey = $priv
Address = 10.100.0.$n/32

[Peer]
PublicKey = $(cat vpn-server.pub)
Endpoint = $endpoint
AllowedIPs = 10.100.0.0/24, 10.100.1.0/24
PersistentKeepalive = 25
CONF
command -v qrencode >/dev/null && echo "(for a phone: save the block above as a file and 'qrencode -t ansiutf8 < file')"
echo; echo "vpn-peers.nix now lists $name; commit it, and the server takes it at the next deploy."
