#!/usr/bin/env bash
# lab/vms-lvm-vm-bakeoff.sh — the VM part of R5 on the thin-LVM pool (ADR 0013), with forced stops; run inside host-v as root after: modprobe dm_thin_pool dm_snapshot; incus storage create lvmpool lvm source=<a loop device>
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH
ms() { echo $(( $(date +%s%N) / 1000000 )); }; I="incus"
pkill -f "incus stop" ; $I delete -f vl vl2 </dev/null >/dev/null 2>&1
$I launch lab-ubuntu-vm vl --vm -s lvmpool -c limits.memory=1GiB --quiet </dev/null >/dev/null 2>&1
w() { for i in $(seq 1 120); do $I exec $1 -- true </dev/null 2>/dev/null && return; sleep 1; done; }
w vl; sleep 30; $I exec vl -- sh -c "echo before > /root/m" </dev/null
s=$(ms); $I stop vl </dev/null; echo "stop (settled) $(( $(ms)-s )) ms"
s=$(ms); $I snapshot create vl s1 </dev/null; echo "snapshot $(( $(ms)-s )) ms"
$I start vl </dev/null; w vl; sleep 30; $I exec vl -- sh -c "echo after > /root/m" </dev/null
s=$(ms); $I stop -f vl </dev/null; echo "forced stop $(( $(ms)-s )) ms"
s=$(ms); $I snapshot restore vl s1 </dev/null 2>&1 | head -n 2; echo "restore $(( $(ms)-s )) ms"
s=$(ms); $I start vl </dev/null; w vl; echo "restore, boot, answering $(( $(ms)-s )) ms; marker after restore: $($I exec vl -- cat /root/m </dev/null)"
sleep 20; $I stop -f vl </dev/null
s=$(ms); $I copy vl vl2 -s lvmpool </dev/null; echo "clone $(( $(ms)-s )) ms"
lvs --noheadings -o lv_name,lv_size,data_percent 2>/dev/null | grep -i "vl" | tr -s " "
s=$(ms); $I delete -f vl vl2 </dev/null; echo "delete $(( $(ms)-s )) ms"
