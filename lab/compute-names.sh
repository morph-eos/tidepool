#!/usr/bin/env bash
# =============================================================================
# lab/compute-names.sh — the names <instance>.compute.<domain> of compute-names.nix (issue 11)
#
# Usage: lab/compute-names.sh <vm-name>      (a NixOS lab VM with Incus, built from the flake in ~/nixos-new/nixos; it is switched to the host lab-compute)
#
# Checks, with one container and one VM:
#   a private instance answers on the VPN address and not on the public one; a listed one answers on both; an instance created afterwards answers with no change;
#   an unknown name gets an error and not another site; other ports of an instance are not reached through the name.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="${1:?usage: compute-names.sh <vm-name>}"
tar -C "$HERE/.." -c nixos | "$HERE/vm.sh" ssh "$NAME" 'rm -rf ~/nixos-new && mkdir ~/nixos-new && tar x -C ~/nixos-new'
"$HERE/vm.sh" ssh "$NAME" 'bash -s' <<'REMOTE_EOF'
r() { # r <description> <expected> <command...>
  local desc="$1" want="$2"; shift 2; local got; got=$("$@" 2>/dev/null)
  if [ "$got" = "$want" ]; then echo "PASS $desc"; else echo "FAIL $desc (wanted '$want', got '$got')"; fi
}
# Pebble keeps its accounts in memory: after a reboot the ones lego saved are unknown to it
sudo rm -rf /var/lib/acme/.lego/accounts; sudo systemctl reset-failed
sudo nixos-rebuild test --flake path:$HOME/nixos-new/nixos#lab-compute 2>&1 | tail -1
sudo systemctl restart 'acme-order-renew-*.service' nginx; sleep 8
# incus reads its standard input, which here is the rest of this script
inc() { sudo incus "$@" </dev/null; }
get() { curl -sk -o /dev/null -w '%{http_code}' --max-time 8 --resolve "$1:443:$2" "https://$1/"; }
# prints "no" when the answer is not an instance's page
nothello() { case $(body "$@") in hello-*) echo yes;; *) echo no;; esac; }
body() { curl -sk --max-time 8 --resolve "$1:443:$2" "https://$1/"; }
# an instance serves its name on port 80, and something else on 8080 (which the name must never reach)
serve() {
  for i in $(seq 1 60); do inc list "$1" -f csv -c 4 | grep -q 10.100.1 && break; sleep 2; done
  for i in $(seq 1 30); do inc exec "$1" -- apk add -q busybox-extras >/dev/null 2>&1 && break; sleep 2; done
  inc exec "$1" -- sh -c "mkdir -p /www /www8; echo hello-$1 > /www/index.html; echo port8080 > /www8/index.html; httpd -p 80 -h /www; httpd -p 8080 -h /www8"
}
launch() { inc launch images:alpine/3.21 "$@" >/dev/null 2>&1; for i in $(seq 1 60); do inc exec "$1" -- true 2>/dev/null && return; sleep 2; done; }
launch priv; launch pub
inc launch images:alpine/3.21 virt --vm -c security.secureboot=false -c limits.memory=512MiB >/dev/null 2>&1
for i in $(seq 1 90); do inc exec virt -- true 2>/dev/null && break; sleep 2; done
serve priv; serve pub; serve virt
V=10.100.0.1; P=127.0.0.1; D=lab.test
r "a private container answers on the VPN address"            hello-priv  body priv.compute.$D $V
r "a private VM answers on the VPN address"                   hello-virt  body virt.compute.$D $V
r "a private container is not served on the public listener"  no          nothello priv.compute.$D $P
r "a listed container answers on the public listener"         hello-pub   body pub.compute.$D $P
r "a listed container also answers on the VPN address"        hello-pub   body pub.compute.$D $V
r "an unknown instance is a 502, not another site"            502         get nobody.compute.$D $V
launch later; serve later; sleep 3
r "an instance created afterwards answers with no change"     hello-later body later.compute.$D $V
r "the name never reaches port 8080 of the instance"          hello-pub   body pub.compute.$D $V
# the other virtual hosts still answer, and a name that is nobody's gets no answer on both addresses, never another service's page
r "a name that is nobody's gets no answer (VPN address)"    000         get nobody.lab.test $V
r "a name that is nobody's gets no answer (public address)" 000         get nobody.lab.test $P
r "the same over plain HTTP"                                000         curl -s -o /dev/null -w '%{http_code}' --max-time 8 --resolve nobody.lab.test:80:$V http://nobody.lab.test/
r "a name with a dot under compute gets no answer"          000         get a.b.compute.$D $V
r "a VPN-only service still answers on the VPN address"     200         get sync.$D $V
# the bridge's DNS through the VPN address (a raw query: the lab VM has no dig)
dnsq() { python3 - "$1" "$2" <<'PY'
import socket, struct, sys
name, server = sys.argv[1], sys.argv[2]
q = struct.pack(">HHHHHH", 0x1234, 0x0100, 1, 0, 0, 0) + b"".join(bytes([len(l)]) + l.encode() for l in name.split(".")) + b"\0" + struct.pack(">HH", 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(5); s.sendto(q, (server, 53))
try:
    a = s.recv(512)
    print(".".join(str(b) for b in a[-4:]) if a[3] & 15 == 0 and struct.unpack(">H", a[6:8])[0] else "none")
except Exception:
    print("none")
PY
}
r "the VPN address answers .incus names (ssh by name)"      "$(inc list priv -f csv -c 4 | cut -d' ' -f1)"  dnsq priv.incus $V
echo "failed units: $(systemctl --failed --no-legend | wc -l)"
inc delete -f priv pub virt later >/dev/null 2>&1
REMOTE_EOF
