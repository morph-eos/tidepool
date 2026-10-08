#!/usr/bin/env bash
# =============================================================================
# lab/experiments/vms-others-bakeoff.sh <libvirt|microvm> — phase 6 (ADR 0013), R3 and R4. Runs INSIDE host-v as root, booted into that specialisation.
# =============================================================================
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH
say() { printf '  %s\n' "$*"; }
case "${1:?variant}" in
libvirt)
  echo "== R3 libvirt (domain and network declared through NixVirt)"
  sleep 20
  say "libvirtd: $(systemctl is-active libvirtd); version $(virsh version 2>/dev/null | grep -m1 'Using library' | cut -c1-40)"
  say "the declared network: $(virsh net-list --all 2>&1 | sed -n 3p | tr -s ' ')"
  say "the declared domain: $(virsh list --all 2>&1 | sed -n 3p | tr -s ' ')"
  sleep 30; say "R3 the VM booted the installer ISO (serial log): $(grep -a -m1 -o 'Welcome to Alpine[^\\r]*\|localhost login' /var/lib/lab/iso.log 2>/dev/null | head -n 1 || echo 'no banner yet'); log bytes: $(stat -c %s /var/lib/lab/iso.log 2>/dev/null)"
  say "R3 containers: $(virsh -c lxc:/// list 2>&1 | head -n 1 | cut -c1-80)"
  say "R3 firewall: tables $(nft list tables | awk '{print $2"/"$3}' | tr '\n' ' ')"
  say "R3 memory: host $(free -m | sed -n 2p | awk '{print $3}') MiB used, libvirtd $(systemctl show libvirtd -p MemoryCurrent --value | awk '{printf "%d", $1/1048576}') MiB"
  say "R3 snapshot of a running domain with a raw/ISO disk: $(virsh snapshot-create-as lab-iso s1 2>&1 | head -n 1 | cut -c1-110)"
  ;;
microvm)
  echo "== R4 microvm.nix (a NixOS guest declared in the flake)"
  sleep 40
  say "unit: $(systemctl is-active microvm@lab1); virtiofsd: $(systemctl is-active microvm-virtiofsd@lab1)"
  t=0; until curl -s --max-time 3 -o /dev/null http://127.0.0.1:8070/ || [ $t -ge 120 ]; do sleep 3; t=$((t+3)); done
  say "the guest's nginx answers through the forwarded port: HTTP $(curl -s --max-time 4 -o /dev/null -w %{http_code} http://127.0.0.1:8070/) (waited $t s after the 40 s)"
  say "memory: guest given 512 MiB; the VM's qemu process uses $(ps aux | grep '[.]qemu-system' | awk '{s+=$6} END {printf "%d", s/1024}') MiB; host $(free -m | sed -n 2p | awk '{print $3}') MiB used"
  say "the guest's system is the host's store, read-only (virtiofs): $(ls /var/lib/microvms/lab1 2>/dev/null | tr '\n' ' ')"
  say "can it boot an installer ISO or a non-NixOS image? no: the guest is a NixOS closure built by the flake"
  ;;
esac
