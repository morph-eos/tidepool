#!/usr/bin/env bash
# =============================================================================
# lab/vms-engines-bakeoff.sh <docker|podman> — phase 6 (ADR 0013), R2: a container engine next to Incus, with the host firewall on (nftables, forward filtering).
# Runs INSIDE host-v as root, booted into the specialisation of that engine, with the Incus instances ct1 (Alpine) and web (OCI nginx) running.
# "outside" is a network namespace joined to the host by a virtual cable (traffic arrives on a real interface).
# =============================================================================
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH
E=${1:?engine}
say() { printf '  %s\n' "$*"; }
img=docker.io/library/nginx:alpine
echo "== R2 $E next to Incus (variant: $(basename $(readlink /run/current-system) | cut -c1-12), host firewall forward filtering on)"
say "$E: $($E --version | head -n 1); nftables rules written by the engine: $(nft list ruleset | grep -c "docker\|netavark\|DOCKER\|NETAVARK"); netavark/firewall: $( [ $E = podman ] && podman info --format '{{.Host.NetworkBackend}} {{.Host.NetworkBackendInfo.Version}}' 2>/dev/null || echo n/a)"
$E rm -f e1 e2 >/dev/null 2>&1
$E network rm -f labnet >/dev/null 2>&1; $E network create labnet >/dev/null 2>&1
WEB=$(incus list web -f csv -c 4 | cut -d' ' -f1); CT=$(incus list ct1 -f csv -c 4 | cut -d' ' -f1)
$E run -d --name e1 --network labnet -p 8080:80 $img >/dev/null 2>&1 || say "could not start e1 (pull or run failed)"
$E run -d --name e2 --network labnet $img >/dev/null 2>&1
sleep 3
ip_of() { if [ $E = docker ]; then docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $1; else podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $1; fi; }
E1=$(ip_of e1); E2=$(ip_of e2)
say "addresses: engine containers $E1 $E2; Incus: web $WEB, ct1 $CT"
chk() { # chk <label> <command...>: prints ok or FAIL
  local l=$1; shift; if "$@" >/dev/null 2>&1; then echo "ok"; else echo "FAIL"; fi
}
ee() { $E exec e2 "$@"; }
say "T1 engine container to the Internet: $(chk x ee wget -qO- -T6 http://example.com)"
say "T2 engine container to an Incus instance (web, port 80): $(chk x ee wget -qO- -T6 http://$WEB)"
say "T3 Incus system container to the Internet: $(chk x incus exec ct1 -- wget -qO- -T6 http://example.com)"
say "T4 Incus instance to an engine container (e2, port 80): $(chk x incus exec ct1 -- wget -qO- -T6 http://$E2)"
say "T5 name resolution between engine containers (e2 asks for e1 by name): $(chk x ee wget -qO- -T6 http://e1)"
ip netns del outside 2>/dev/null; ip link del veth-out 2>/dev/null
ip netns add outside; ip link add veth-out type veth peer name veth-in; ip link set veth-in netns outside
ip addr add 192.168.50.1/24 dev veth-out; ip link set veth-out up
ip -n outside addr add 192.168.50.2/24 dev veth-in; ip -n outside link set veth-in up; ip -n outside link set lo up; ip -n outside route add default via 192.168.50.1
O="ip netns exec outside curl -s --max-time 5 -o /dev/null -w %{http_code}"
say "T6 THE GATE: a port published by the engine (-p 8080:80), NO line for it in the host firewall, asked from outside: $($O http://192.168.50.1:8080/ 2>&1 | head -c 20) (000 = no answer, 200 = reachable)"
say "T6 an unpublished port of the host (8081) from outside: $($O http://192.168.50.1:8081/ 2>&1 | head -c 20)"
say "T6 an engine container's own address from outside, unpublished (e2): $(ip netns exec outside curl -s --max-time 4 -o /dev/null -w %{http_code} http://$E2/ 2>&1 | head -c 20) (the outside has no route to it; reached through the host as a router?)"
ip -n outside route add ${E2%.*}.0/24 via 192.168.50.1 2>/dev/null
say "T6 the same with a route to the container network added on the outside: $(ip netns exec outside curl -s --max-time 4 -o /dev/null -w %{http_code} http://$E2/ 2>&1 | head -c 20)"
$E run -d --name e3 --network labnet -p 127.0.0.1:8081:80 $img >/dev/null 2>&1; sleep 2
say "T6b a port published WITH an explicit loopback address (-p 127.0.0.1:8081:80): from outside: $($O http://192.168.50.1:8081/ 2>&1 | head -c 20); from the host itself: $(curl -s --max-time 4 -o /dev/null -w %{http_code} http://127.0.0.1:8081/)"
$E rm -f e3 >/dev/null 2>&1
$E run -d --name e4 --network labnet -p 9090:80 $img >/dev/null 2>&1; sleep 2
say "T6c the publication gate (variants 'declared' only: a table lists 9090 as the one port that may be public): -p 9090:80 from outside: $($O http://192.168.50.1:9090/ 2>&1 | head -c 20); -p 8080:80 (not listed) from outside: $($O http://192.168.50.1:8080/ 2>&1 | head -c 20)"
$E rm -f e4 >/dev/null 2>&1
say "T7 who owns the firewall: nft tables: $(nft list tables | awk '{print $2"/"$3}' | tr '\n' ' ')"
say "T8 restart the host firewall (as a rebuild's reload does): nftables.service restart"
systemctl restart nftables.service; sleep 3
say "T8 after it: engine container to the Internet: $(chk x ee wget -qO- -T6 http://example.com); published port from outside: $($O http://192.168.50.1:8080/ 2>&1 | head -c 20); Incus ct1 to the Internet: $(chk x incus exec ct1 -- wget -qO- -T6 http://example.com); engine to Incus web: $(chk x ee wget -qO- -T6 http://$WEB)"
say "T9 restart the engine, then ask Incus: ct1 to the Internet: $( systemctl restart $E.service 2>/dev/null || systemctl restart podman.socket; sleep 3; chk x incus exec ct1 -- wget -qO- -T6 http://example.com)"
say "T9 restart Incus, then the engine: e2 to the Internet: $( systemctl restart incus.service; sleep 6; $E start e2 >/dev/null 2>&1; sleep 2; chk x ee wget -qO- -T6 http://example.com)"
say "memory at idle with the engine and two containers: host $(free -m | sed -n 2p | awk '{print $3}') MiB used; engine daemon: $(systemctl show docker -p MemoryCurrent --value 2>/dev/null | awk '{printf "%d MiB", $1/1048576}')"
$E rm -f e1 e2 >/dev/null 2>&1
if [ $E = podman ] && systemctl cat podman-lab-web.service >/dev/null 2>&1; then
  say "T10 declared container (oci-containers, digest-pinned): unit $(systemctl is-active podman-lab-web.service); answers on its loopback port: $(curl -s --max-time 4 -o /dev/null -w %{http_code} http://127.0.0.1:8090/); from outside: $($O http://192.168.50.1:8090/ 2>&1 | head -c 20)"
  podman kill lab-web >/dev/null 2>&1; sleep 8; say "T10 after the container is killed, the unit brought it back: $(systemctl is-active podman-lab-web.service), answering: $(curl -s --max-time 4 -o /dev/null -w %{http_code} http://127.0.0.1:8090/)"
  say "T10 the image reference in use: $(podman inspect lab-web --format '{{.ImageName}}' | cut -c1-90)"
fi
$E rm -f e1 e2 >/dev/null 2>&1; $E network rm labnet >/dev/null 2>&1
