#!/usr/bin/env bash
# =============================================================================
# lab/experiments/vms-cycle-bakeoff.sh — phase 6 (ADR 0013), R5: the throwaway cycle on Incus, on a ZFS pool against a plain directory pool, for a container and a VM.
# Runs INSIDE host-v as root (the base configuration), with the images lab-alpine and lab-ubuntu-vm cached.
# =============================================================================
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH
say() { printf '  %s\n' "$*"; }
ms() { echo $(( $(date +%s%N) / 1000000 )); }
el() { echo "$(( $(ms) - $1 )) ms"; }
echo "== R5 the throwaway cycle"
incus delete -f c-zp c-dir v-zp v-dir c-zp2 v-zp2 c-dir2 v-dir2 >/dev/null 2>&1
waitexec() { local n=$1 s=$(ms); while ! incus exec "$n" -- true >/dev/null 2>&1 </dev/null; do sleep 0.3; [ $(( $(ms) - s )) -gt 120000 ] && { echo timeout; return 1; }; done; }
for pool in zp dirpool; do
  tag=$([ $pool = zp ] && echo zp || echo dir)
  echo "-- pool $pool"
  s=$(ms); incus launch lab-alpine c-$tag -s $pool >/dev/null 2>&1 </dev/null; waitexec c-$tag; say "container: create and answering exec: $(el $s)"
  incus exec c-$tag -- sh -c 'echo before > /root/marker' </dev/null
  s=$(ms); incus snapshot create c-$tag s1 >/dev/null 2>&1 </dev/null; say "container: snapshot: $(el $s)"
  incus exec c-$tag -- sh -c 'echo after > /root/marker' </dev/null
  s=$(ms); incus snapshot restore c-$tag s1 >/dev/null 2>&1 </dev/null; say "container: restore: $(el $s); marker after restore: $(incus exec c-$tag -- cat /root/marker </dev/null 2>&1)"
  s=$(ms); incus copy c-$tag c-${tag}2 -s $pool >/dev/null 2>&1 </dev/null; say "container: clone: $(el $s)"
  s=$(ms); incus delete -f c-${tag}2 c-$tag >/dev/null 2>&1 </dev/null; say "container: delete both: $(el $s)"

  s=$(ms); incus launch lab-ubuntu-vm v-$tag --vm -s $pool -c limits.memory=1GiB -c limits.cpu=2 >/dev/null 2>&1 </dev/null; waitexec v-$tag; say "VM: create and agent answering: $(el $s)"
  incus exec v-$tag -- sh -c 'echo before > /root/marker' </dev/null
  s=$(ms); incus stop v-$tag >/dev/null 2>&1 </dev/null; say "VM: stop: $(el $s)"
  s=$(ms); incus snapshot create v-$tag s1 >/dev/null 2>&1 </dev/null; say "VM: snapshot (stopped): $(el $s)"
  incus start v-$tag >/dev/null 2>&1 </dev/null; waitexec v-$tag; incus exec v-$tag -- sh -c 'echo after > /root/marker' </dev/null; incus stop v-$tag >/dev/null 2>&1 </dev/null
  s=$(ms); incus snapshot restore v-$tag s1 >/dev/null 2>&1 </dev/null; say "VM: restore (stopped): $(el $s)"
  s=$(ms); incus start v-$tag >/dev/null 2>&1 </dev/null; waitexec v-$tag; say "VM: restore, boot and answering: $(el $s) in total; marker: $(incus exec v-$tag -- cat /root/marker </dev/null 2>&1)"
  incus stop v-$tag >/dev/null 2>&1 </dev/null
  s=$(ms); incus copy v-$tag v-${tag}2 -s $pool >/dev/null 2>&1 </dev/null; say "VM: clone (stopped, 10 GiB disk): $(el $s)"
  if [ $pool = zp ]; then say "space: the VM's volume uses $(zfs list -H -o used -t volume zp/virtual-machines/v-$tag.block) of 10G, the clone adds $(zfs list -H -o used -t volume zp/virtual-machines/v-${tag}2.block)"; else say "space: the VM's disk file uses $(du -sh /var/lib/incus/storage-pools/dirpool/virtual-machines/v-$tag/root.img | cut -f1) on disk, the clone $(du -sh /var/lib/incus/storage-pools/dirpool/virtual-machines/v-${tag}2/root.img | cut -f1)"; fi
  s=$(ms); incus delete -f v-${tag}2 v-$tag >/dev/null 2>&1 </dev/null; say "VM: delete both: $(el $s)"
done
echo "-- limits"
incus launch lab-alpine lim -s zp -c limits.memory=64MiB -c limits.cpu=1 >/dev/null 2>&1 </dev/null; waitexec lim
say "memory limit 64MiB: the container sees $(incus exec lim -- free -m </dev/null | sed -n 2p | awk '{print $2}') MiB; cpu limit 1: nproc says $(incus exec lim -- nproc </dev/null)"
incus config device set lim root size=50MiB >/dev/null 2>&1 </dev/null; say "disk quota 50MiB on a ZFS container: df inside says $(incus exec lim -- df -m / </dev/null | tail -n1 | awk '{print $2}') MiB"
incus delete -f lim >/dev/null 2>&1 </dev/null
