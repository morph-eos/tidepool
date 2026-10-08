#!/usr/bin/env bash
# =============================================================================
# lab/gate.sh — the checks to run BEFORE a push or a merge to main, beyond what the CI runs
#
# The CI builds both hosts and runs the unit tests of the rules, the documents' links, the template and the brand's overrides (docs/working-on-it.md). It cannot boot the machine, so the
# checks that need a running lab VM are here. Run this when a change touches what they cover; the table in lab/README.md says which check covers what.
#
# Usage: lab/gate.sh [--full] [--vm NAME] [--only a,b] [--list]
#   (default)  the quick tier, about five minutes, on one NixOS lab VM (default host-m; it is started if it is stopped):
#                smoke   the host `lab` comes up whole: nothing failed, every name answers as it should, Immich runs on its settings (lab/smoke-test.sh)
#                brand   the brand, the single sign-on and Immich's declared settings (lab/brand-test.sh), then the pages in a browser (lab/brand-check.sh)
#                names   the instances' names, the .incus DNS and the silence for unknown names (lab/compute-names.sh)
#   --full     adds the restore drill (lab/restore-drill.sh all, about an hour): the host is rebuilt from blank and restored from Borg and pgBackRest. Needs the VM host-t
#              made as the drill's header says (blank, with its extra disks, installed once)
#   --only     run only the steps named (smoke, brand, names, drill)
#   --list     print the steps and stop
# Output of each step: $GATE_OUT (default /tmp/gate). Exit status: the number of steps that failed (0 = go).
# Not here, on purpose: the Proton Drive copy (it needs a login by hand: lab/proton-offsite/README.md, when the offsite module or the CLI changes) and the one-off experiments (lab/experiments/).
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VMNAME="${GATE_VM:-host-m}"; OUT="${GATE_OUT:-/tmp/gate}"; FULL=0; ONLY=""; LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --full) FULL=1;; --vm) VMNAME="${2:?--vm needs a name}"; shift;; --only) ONLY="${2:?--only needs a list}"; shift;; --list) LIST=1;;
    -h|--help) sed -n 2,26p "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 64;;
  esac; shift
done
STEPS="smoke brand names"; [ "$FULL" = 1 ] && STEPS="$STEPS drill"
[ -n "$ONLY" ] && STEPS="${ONLY//,/ }"
if [ "$LIST" = 1 ]; then printf 'smoke  quick  the lab host comes up whole, the names answer\nbrand  quick  brand, single sign-on, Immich settings, pages in a browser\nnames  quick  instances names, .incus DNS, silence for unknown names\ndrill  full   restore drill (about an hour, needs host-t)\n'; exit 0; fi
mkdir -p "$OUT"
VM="$HERE/vm.sh"
declare -A RESULT NOTE

vm_ready() {
  "$VM" list | awk -v n="$VMNAME" '$1==n {print $2}' | grep -q running || "$VM" start "$VMNAME" || return 1
  "$VM" ssh "$VMNAME" true
}
# a step passes if no line says FAIL and, where the script reports it, no unit failed
verdict() { # verdict <log>
  local log="$1"
  if grep -q '^FAIL' "$log"; then echo "FAIL: $(grep -c '^FAIL' "$log") check(s)"; return 1; fi
  if grep -q '^failed units: [1-9]' "$log"; then echo "FAIL: units failed"; return 1; fi
  if ! grep -q '^PASS' "$log"; then echo "no result lines (see the log)"; return 1; fi
  echo "$(grep -c '^PASS' "$log") checks passed"
}
run_step() {
  local name="$1" log="$OUT/$1.log" rc=0
  echo "== $name"
  case "$name" in
    smoke) vm_ready && "$HERE/smoke-test.sh" "$VMNAME" > "$log" 2>&1; NOTE[$name]="$(verdict "$log")" || rc=1;;
    brand) vm_ready && { "$HERE/brand-test.sh" "$VMNAME" > "$log" 2>&1; "$HERE/brand-check.sh" "$VMNAME" "$OUT/brand-shots" >> "$log" 2>&1; rc=$?; }
           NOTE[$name]="$(verdict "$log")" || rc=1;;
    names) vm_ready && "$HERE/compute-names.sh" "$VMNAME" > "$log" 2>&1; NOTE[$name]="$(verdict "$log")" || rc=1;;
    drill) if "$VM" list | awk '$1=="host-t"{f=1} END{exit !f}'; then "$HERE/restore-drill.sh" all > "$log" 2>&1; grep -q 'DRILL RESULT: PASS' "$log" && NOTE[$name]="DRILL RESULT: PASS" || { NOTE[$name]="$(grep 'DRILL RESULT' "$log" | tail -n 1)"; rc=1; }
           else NOTE[$name]="the VM host-t does not exist (see the header of lab/restore-drill.sh)"; rc=1; fi;;
    *) NOTE[$name]="unknown step"; rc=1;;
  esac
  RESULT[$name]=$rc; echo "   ${NOTE[$name]}"
}
for s in $STEPS; do run_step "$s"; done
echo; echo "== gate ($VMNAME)"; failed=0
for s in $STEPS; do if [ "${RESULT[$s]}" = 0 ]; then echo "PASS  $s: ${NOTE[$s]}"; else echo "FAIL  $s: ${NOTE[$s]}"; failed=$((failed + 1)); fi; done
[ $failed -eq 0 ] && echo "GO: the checks that the CI cannot run pass (logs in $OUT)" || echo "NO GO: $failed step(s) failed (logs in $OUT)"
exit $failed
