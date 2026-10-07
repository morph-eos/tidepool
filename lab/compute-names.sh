#!/usr/bin/env bash
# =============================================================================
# lab/compute-names.sh — the names <instance>.compute.<domain> of vm-names.nix (issue 11)
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
r "an unknown name is an error, not another site"             502         get nobody.compute.$D $V
r "a name with a dot cannot name another host"                no          nothello a.b.compute.$D $V
launch later; serve later; sleep 3
r "an instance created afterwards answers with no change"     hello-later body later.compute.$D $V
r "the name never reaches port 8080 of the instance"          hello-pub   body pub.compute.$D $V
echo "failed units: $(systemctl --failed --no-legend | wc -l)"
inc delete -f priv pub virt later >/dev/null 2>&1
REMOTE_EOF
