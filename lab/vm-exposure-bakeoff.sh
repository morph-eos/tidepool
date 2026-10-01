#!/usr/bin/env bash
# =============================================================================
# lab/vm-exposure-bakeoff.sh — how the services of Incus instances reach the outside (ADR 0010). Runs INSIDE the lab VM, as root, after vpn.nix and vm-exposure.nix are deployed.
# Containers stand in for VMs (same bridge, same DNS). A namespace "phone" is a peer on the VPN; "outside" is joined by a virtual cable. Lab scaffolding.
#   X1 names by the bridge's DNS   X2 a name per instance through the VPN, with no per-instance configuration   X3 the instances' subnet through the VPN
#   X4 one port published on purpose (a declared DNAT)   X5 an Incus proxy device alone   X6 the Incus API
# =============================================================================
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH
say() { printf '  %s\n' "$*"; }
SRVPUB=$(wg show wg0 public-key)
LAN=$(ip -4 -o addr show scope global | grep -v -E 'wg0|docker|br-|incusbr0|veth' | awk '{print $4}' | cut -d/ -f1 | head -n 1)
echo "== instance services (LAN address $LAN)"

cat > /tmp/serve.sh <<'SH'
#!/bin/sh
# a tiny web server for the lab: answers every request with its own name (the Alpine image has no httpd applet)
PORT=$1; MSG="hello-from-$2"
while true; do
  printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' ${#MSG} "$MSG" | nc -l -p "$PORT" >/dev/null 2>&1
done
SH
serve() { # serve <instance>: answers on port 80 and on 8081
    incus file push /tmp/serve.sh "$1"/root/serve.sh >/dev/null 2>&1
    incus exec "$1" -- sh -c "nohup sh /root/serve.sh 80 $1 >/dev/null 2>&1 &" >/dev/null 2>&1
    incus exec "$1" -- sh -c "nohup sh /root/serve.sh 8081 $1 >/dev/null 2>&1 &" >/dev/null 2>&1
}
incus config device override alpha eth0 ipv4.address=10.100.1.50 >/dev/null 2>&1 || incus config device set alpha eth0 ipv4.address=10.100.1.50
incus restart alpha beta; sleep 8
serve alpha; serve beta; sleep 2

ip netns del phone 2>/dev/null; ip netns del outside 2>/dev/null; ip link del veth-out 2>/dev/null
ip netns add outside; ip link add veth-out type veth peer name veth-in; ip link set veth-in netns outside
ip addr add 192.168.50.1/24 dev veth-out; ip link set veth-out up
ip -n outside addr add 192.168.50.2/24 dev veth-in; ip -n outside link set veth-in up; ip -n outside link set lo up; ip -n outside route add default via 192.168.50.1
ip netns add phone; ip link add wgp type wireguard; ip link set wgp netns phone
ip -n phone addr add 10.100.0.2/24 dev wgp
ip netns exec phone wg set wgp private-key /root/wg-peer.key peer "$SRVPUB" endpoint 127.0.0.1:51820 allowed-ips 10.100.0.0/24,10.100.1.0/24 persistent-keepalive 5
ip -n phone link set wgp up; ip -n phone link set lo up; ip -n phone route add 10.100.1.0/24 dev wgp
sleep 4

r=$(incus exec alpha -- nslookup beta.incus 10.100.1.1 2>&1 | grep -E "^Address" | tail -n 1)
say "X1: the bridge's DNS answers for beta.incus: ${r:-no answer}"

p="curl -sk --max-time 8"
a=$(ip netns exec phone $p --resolve alpha.vm.lab.test:443:10.100.0.1 https://alpha.vm.lab.test/ 2>&1 | head -n 1)
b=$(ip netns exec phone $p --resolve beta.vm.lab.test:443:10.100.0.1 https://beta.vm.lab.test/ 2>&1 | head -n 1)
say "X2: through the VPN, alpha.vm.lab.test: ${a:-no answer}; beta.vm.lab.test: ${b:-no answer}"
incus launch images:alpine/3.24 gamma >/dev/null 2>&1; sleep 8; serve gamma; sleep 2
g=$(ip netns exec phone $p --resolve gamma.vm.lab.test:443:10.100.0.1 https://gamma.vm.lab.test/ 2>&1 | head -n 1)
say "X2: a third instance created afterwards, with no configuration anywhere: ${g:-no answer}"
o=$(ip netns exec outside $p --resolve alpha.vm.lab.test:443:"$LAN" https://alpha.vm.lab.test/ 2>&1 | head -n 1; echo "(curl exit ${PIPESTATUS[0]})")
say "X2: the same name from outside: ${o}"

c1=$(ip netns exec phone $p http://10.100.1.50:80/ 2>&1 | head -n 1); c2=$(ip netns exec phone $p http://10.100.1.50:8081/ 2>&1 | head -n 1)
c3=$(ip netns exec outside $p --max-time 4 http://10.100.1.50:80/ 2>&1 | head -n 1; echo "(curl exit ${PIPESTATUS[0]})")
say "X3: the instance's subnet through the VPN, port 80: ${c1:-no answer}; port 8081: ${c2:-no answer}"
say "X3: the same address from outside: ${c3}"

d1=$(ip netns exec outside $p --max-time 6 http://"$LAN":3001/ 2>&1 | head -n 1; echo "(curl exit ${PIPESTATUS[0]})")
d2=$(ip netns exec outside $p --max-time 4 http://"$LAN":3002/ 2>&1 | head -n 1; echo "(curl exit ${PIPESTATUS[0]})")
d3=$(ip netns exec outside $p --max-time 4 http://"$LAN":8081/ 2>&1 | head -n 1; echo "(curl exit ${PIPESTATUS[0]})")
say "X4: the published port 3001 from outside: ${d1}"
say "X4: a port nobody published (3002): ${d2}; the instance's other web port (8081) at the host: ${d3}"

incus config device add alpha p3003 proxy listen=tcp:0.0.0.0:3003 connect=tcp:127.0.0.1:80 >/dev/null 2>&1; sleep 2
e=$(ip netns exec outside $p --max-time 4 http://"$LAN":3003/ 2>&1 | head -n 1; echo "(curl exit ${PIPESTATUS[0]})")
say "X5: an Incus proxy device listening on 3003, from outside: ${e}; listening on the host: $(ss -ltn | grep -c ':3003 ') socket(s)"
incus config device remove alpha p3003 >/dev/null 2>&1

f1=$(ip netns exec phone $p https://10.100.0.1:8443/ 2>&1 | head -c 70)
f2=$(ip netns exec outside $p --max-time 4 https://"$LAN":8443/ 2>&1 | head -c 70; echo " (curl exit ${PIPESTATUS[0]})")
say "X6: the Incus API through the VPN: ${f1:-no answer}; from outside: ${f2}"

incus delete -f gamma >/dev/null 2>&1
ip netns del phone; ip netns del outside 2>/dev/null; ip link del veth-out 2>/dev/null
