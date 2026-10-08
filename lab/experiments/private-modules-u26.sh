#!/usr/bin/env bash
# lab/experiments/private-modules-u26.sh — a private repository adds a module of its own to the public host without replacing anything (private-repo-template/README.md, "Adding your own modules").
# Needs the lab host `host-m` (lab/vm.sh) installed from this repository. The public tree and lab/experiments/private-modules/ are copied to it; the host is switched to lab-extra.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; VM="$HERE/vm.sh"; ROOT="$(dirname "$HERE")"
(cd "$ROOT" && tar cf - --exclude=.git nixos) | "$VM" ssh host-m 'rm -rf ~/pub && mkdir ~/pub && tar -C ~/pub -xf -'
(cd "$HERE/private-modules" && tar cf - .) | "$VM" ssh host-m 'rm -rf ~/extra && mkdir ~/extra && tar -C ~/extra -xf -'
cat <<'R' | "$VM" ssh host-m 'bash -s' 2>&1 | grep -v "^warning\|^evaluation warning" | tail -n 20
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH NIX_CONFIG="experimental-features = nix-command flakes
download-attempts = 60"
cd ~/extra && nix flake lock >/dev/null 2>&1
sudo -E env PATH=$PATH nixos-rebuild switch --flake path:$HOME/extra#lab-extra >/tmp/extra.log 2>&1; echo "switch exit: $?"
ok=0; bad=0; chk() { if [ "$2" = "$3" ]; then echo "  ok   $1"; ok=$((ok+1)); else echo "  FAIL $1: expected [$2] got [$3]"; bad=$((bad+1)); fi; }
sleep 3
chk "the module's service runs" active "$(systemctl is-active hello)"
chk "its own secret was decrypted from its own file" yes "$(sudo test -s /run/secrets/hello-env && echo yes)"
chk "its virtual host answers through the public nginx" 200 "$(sleep 2; curl -sk -o /dev/null -w '%{http_code}' --resolve hello.lab.test:443:127.0.0.1 https://hello.lab.test/)"
# the unit starts a wrapper that execs the job's script; the backed-up paths are in that script (as `systemctl cat` does not show)
bs=$(sudo grep -oE '/nix/store/[a-z0-9]{32}-borgbackup-job-everything-script' "$(systemctl cat borgbackup-job-everything | grep '^ExecStart=' | head -1 | cut -d= -f2 | cut -d' ' -f1)")
chk "its path joined the Borg job" yes "$(sudo grep -q '/var/lib/private/hello' "$bs" && echo yes)"
chk "the public paths are still there" yes "$(sudo grep -q '/srv/data' "$bs" && echo yes)"
chk "the public services were not touched" active "$(systemctl is-active nginx)"
echo "private-modules: $ok ok, $bad failed"
R
