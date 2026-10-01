#!/usr/bin/env bash
# =============================================================================
# lab/vpn-bakeoff.sh — a WireGuard peer in a network namespace stands for a phone on the VPN; "outside" is the machine's own LAN address. ADR 0009. Lab scaffolding.
# Needs the fixtures of nixos/modules/edge/common.nix, nginx.nix and vpn.nix (the peer's key in /root/wg-peer.key, its public half in vpn.nix).
#   V1 the handshake   V2 a VPN-only name through the VPN   V3 the same name from outside   V4 a public name still answers from outside
#   V5 a VPN-only port   V6 a key that is not in the configuration
# =============================================================================
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH
say() { printf '  %s\n' "$*"; }
SRVPUB=$(wg show wg0 public-key)
LAN=$(ip -4 -o addr show scope global | grep -v -E 'wg0|docker|br-' | awk '{print $4}' | cut -d/ -f1 | head -n 1)
curl -s --cacert /etc/ssl/certs/ca-certificates.crt https://localhost:15000/roots/0 > /tmp/pebble-root.pem
curl -s --cacert /etc/ssl/certs/ca-certificates.crt https://localhost:15000/intermediates/0 >> /tmp/pebble-root.pem
echo "== WireGuard through the NixOS module (LAN address $LAN)"

ip netns del phone 2>/dev/null; ip netns del intruder 2>/dev/null; ip netns del outside 2>/dev/null; ip link del veth-out 2>/dev/null
# "outside": a namespace joined to the machine by a virtual cable, so its traffic arrives on a real interface and not on the loopback (which the firewall always allows)
ip netns add outside; ip link add veth-out type veth peer name veth-in; ip link set veth-in netns outside
ip addr add 192.168.50.1/24 dev veth-out; ip link set veth-out up
ip -n outside addr add 192.168.50.2/24 dev veth-in; ip -n outside link set veth-in up; ip -n outside link set lo up; ip -n outside route add default via 192.168.50.1
# wait until the certificates of the names we use are the test CA's
for i in $(seq 1 60); do
  ok=0; for n in admin.lab.test plain.lab.test; do
    h=$([ "$n" = admin.lab.test ] && echo 10.100.0.1 || echo 127.0.0.1)
    echo | timeout 5 openssl s_client -connect $h:443 -servername $n 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | grep -q Pebble && ok=$((ok+1)); done
  [ $ok -eq 2 ] && break; sleep 2; done
ip netns add phone
ip link add wgp type wireguard; ip link set wgp netns phone
ip -n phone addr add 10.100.0.2/24 dev wgp
ip netns exec phone wg set wgp private-key /root/wg-peer.key peer "$SRVPUB" endpoint 127.0.0.1:51820 allowed-ips 10.100.0.0/24 persistent-keepalive 5
ip -n phone link set wgp up; ip -n phone link set lo up

sleep 4
hs=$(wg show wg0 latest-handshakes | awk '{print $2}')
say "V1: handshake with the peer: $([ "${hs:-0}" -gt 0 ] && echo "yes, $(( $(date +%s) - hs )) s ago" || echo "NONE")"

r=$(ip netns exec phone curl -s --max-time 8 --cacert /tmp/pebble-root.pem --resolve admin.lab.test:443:10.100.0.1 https://admin.lab.test/ 2>&1 | head -c 90)
say "V2: from the peer, https://admin.lab.test/ (10.100.0.1): ${r:-no answer}"

r=$(ip netns exec outside curl -s --max-time 8 --cacert /tmp/pebble-root.pem --resolve admin.lab.test:443:"$LAN" https://admin.lab.test/ 2>&1 | head -c 90; echo " (curl exit ${PIPESTATUS[0]})")
say "V3: from outside, admin.lab.test at the LAN address: ${r}"

r=$(ip netns exec outside curl -s --max-time 8 --cacert /tmp/pebble-root.pem --resolve plain.lab.test:443:"$LAN" https://plain.lab.test/ 2>&1 | head -c 70)
say "V4: from outside, a public name (plain.lab.test) at the LAN address: ${r:-no answer}"

a=$(ip netns exec phone timeout 4 nc 10.100.0.1 7777 2>&1 | head -n 1)
b=$(ip netns exec outside timeout 4 nc "$LAN" 7777 2>&1 | head -n 1; echo "(nc exit ${PIPESTATUS[0]})")
say "V5: port 7777 from the peer: ${a:-no answer}; from outside: ${b}"

ip netns add intruder; ip link add wgi type wireguard; ip link set wgi netns intruder
k=$(wg genkey)
ip -n intruder addr add 10.100.0.9/24 dev wgi
echo "$k" | ip netns exec intruder wg set wgi private-key /dev/stdin peer "$SRVPUB" endpoint 127.0.0.1:51820 allowed-ips 10.100.0.0/24 persistent-keepalive 5
ip -n intruder link set wgi up; ip -n intruder link set lo up
sleep 4
c=$(ip netns exec intruder timeout 4 nc 10.100.0.1 7777 2>&1 | head -n 1; echo "(exit ${PIPESTATUS[0]})")
say "V6: a peer whose key is not in the configuration reaches port 7777: ${c}"
wg show wg0 | grep -c '^peer:' | xargs -I{} echo "  peers known to the server: {} (the intruder is not one of them)"
ip netns del phone; ip netns del intruder 2>/dev/null; ip netns del outside 2>/dev/null; ip link del veth-out 2>/dev/null
