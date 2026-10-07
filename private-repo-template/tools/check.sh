#!/usr/bin/env bash
# What is still missing before the day: placeholders in host.nix and in secrets.yaml, and whether the host builds. Exit status = the number of problems.
# Usage: tools/check.sh [--build]       (--build also evaluates the whole host: needs Nix)
set -uo pipefail
cd "$(dirname "$0")/.."
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/tidepool/age.key}"
SOPS="${SOPS:-sops}"
bad=0
if grep -n 'REPLACE' host.nix; then bad=$((bad+1)); echo "^ host.nix still has placeholders"; fi
if [ ! -e secrets.yaml ]; then echo "no secrets.yaml: run tools/secrets-init.sh"; bad=$((bad+1))
else
  plain=$($SOPS -d secrets.yaml 2>/dev/null)
  left=$(printf '%s\n' "$plain" | grep -o '^[a-z-]*:.*REPLACE[-a-z0-9_]*' | sed 's/:.*//' | sort -u)
  printf '%s\n' "$plain" | grep -q '"\(username\|password\)": "REPLACE' && left=$(printf '%s\nacme-dns-credentials (username and password of each registration)\n' "$left" | sort -u)
  if [ -n "$left" ]; then echo "secrets.yaml, not real yet:"; echo "$left" | sed 's/^/  /'; bad=$((bad+1)); fi
fi
[ -e deploy.pub ] && echo "(deploy.pub must be a read-only deploy key of this repository on GitHub)"
if [ "${1:-}" = --build ]; then
  nix build .#nixosConfigurations.tidepool.config.system.build.toplevel --no-link || bad=$((bad+1))
fi
[ "$bad" = 0 ] && echo "ready" || echo "$bad thing(s) to do"
exit "$bad"
