#!/usr/bin/env bash
# =============================================================================
# lab/experiments/vms-bakeoff.sh — phase 6 (ADR 0013). Runs INSIDE the lab VM host-v, as root, with modules/vms/incus.nix deployed and the ZFS pool "zp" created.
#   R1 what Incus can run from one tool: a system container, a VM from a cloud image, a VM booted from an installer ISO, an OCI application container
# =============================================================================
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH
say() { printf '  %s\n' "$*"; }
now() { date +%s; }
wait_for() { local t=$1; shift; local s=$(now); while [ $(( $(now) - s )) -lt "$t" ]; do "$@" >/dev/null 2>&1 && { echo $(( $(now) - s )); return 0; }; sleep 2; done; echo "none in ${t}"; return 1; }
echo "== R1 what Incus runs from one tool"
incus delete -f ct1 ct2 vm1 isovm web >/dev/null 2>&1
# the images are fetched first and timed apart, so that the start times below are the manager's own
s=$(now); incus image copy images:alpine/3.24 local: --alias lab-alpine --quiet >/dev/null 2>&1; say "image alpine/3.24 (container) fetched in $(( $(now) - s )) s over the lab's link"
s=$(now); incus image copy images:ubuntu/24.04/cloud local: --vm --alias lab-ubuntu-vm --quiet >/dev/null 2>&1; say "image ubuntu/24.04/cloud (VM) fetched in $(( $(now) - s )) s"

s=$(now); incus launch lab-alpine ct1 >/dev/null 2>&1 </dev/null; t=$(wait_for 120 incus exec ct1 -- true); say "R1a system container (Alpine, image cached): answering exec after $t s"
say "R1a its pool: $(incus config show ct1 --expanded | grep -A3 'root:' | grep pool | tr -d ' '); the disk is a ZFS dataset: $(zfs list -H -o name | grep -c containers/ct1)"

s=$(now); incus launch lab-ubuntu-vm vm1 --vm -c limits.memory=1GiB -c limits.cpu=2 >/dev/null 2>&1 </dev/null; t=$(wait_for 300 incus exec vm1 -- true); say "R1b VM from a cloud image (Ubuntu 24.04, image cached), nested on the lab's KVM: answering exec after $t s"
sleep 20; say "R1b the profile's cloud-init created the admin user: $(incus exec vm1 -- id vm-admin 2>&1 | head -n 1 | cut -c1-60); kernel: $(incus exec vm1 -- uname -r 2>&1)"
say "R1b the VM's disk is a ZFS volume: $(zfs list -H -o name,volsize -t volume | grep vm1 | head -n 1)"; say "R1b VM memory seen by the guest: $(incus exec vm1 -- free -m 2>/dev/null | sed -n 2p | awk '{print $2}') MiB"

[ -f /tmp/alpine.iso ] || curl -sfL -o /tmp/alpine.iso https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/alpine-virt-3.22.1-x86_64.iso
incus init isovm --empty --vm -c limits.memory=1GiB -c security.secureboot=false >/dev/null 2>&1
incus config device add isovm cd disk source=/tmp/alpine.iso boot.priority=10 >/dev/null 2>&1
s=$(now); incus start isovm >/dev/null 2>&1 </dev/null; t=$(wait_for 180 sh -c "incus console isovm --show-log 2>/dev/null | grep -q 'Welcome to Alpine\|localhost login'"); say "R1c a VM booted from an installer ISO (Alpine, UEFI, secure boot off): the installer's banner appeared after $t s; last console line: $(incus console isovm --show-log 2>/dev/null | grep -v '^$' | tail -n 1 | cut -c1-70)"
incus stop -f isovm >/dev/null 2>&1

incus remote add docker https://docker.io --protocol=oci >/dev/null 2>&1 || true
s=$(now); out=$(incus launch docker:nginx:alpine web --quiet 2>&1 </dev/null | tail -n 1); t=$(wait_for 400 sh -c "incus list web -f csv -c 4 | grep -q 10.100"); ip=$(incus list web -f csv -c 4 | cut -d' ' -f1); say "R1d OCI application container (nginx:alpine from Docker Hub): ${out:-launched}; has an address after $t s ($ip); total $(( $(now) - s )) s"
say "R1d it answers on port 80: $(curl -s --max-time 5 -o /dev/null -w '%{http_code}' http://$ip/)"
say "R1d the container runs the image's own command, no init system: $(incus exec web -- ps 2>/dev/null | awk 'NR>1{print $4}' | sort | uniq -c | tr '\n' ' ')"
inc=$(skopeo inspect docker://docker.io/library/nginx:alpine 2>/dev/null | jq -r .Digest); say "R1d pinned by digest: launching docker:nginx@${inc:0:19}...: $(incus launch docker:nginx@$inc webd --quiet >/dev/null 2>&1 </dev/null && echo launched || echo FAILED)"
incus delete -f webd >/dev/null 2>&1

say "R1e web UI: https://127.0.0.1:8443/ui/ answers $(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:8443/ui/)"
say "R1f instances now: $(incus list -f csv -c nt | tr '\n' ' ')"
say "R1g memory: host $(free -m | sed -n 2p | awk '{print $3}') MiB used; the incus service group (the daemon, dnsmasq and the QEMU of every running VM) $(systemctl show incus -p MemoryCurrent --value | awk '{printf "%d", $1/1048576}') MiB; the VM was given 1 GiB, the stopped ISO VM none"
