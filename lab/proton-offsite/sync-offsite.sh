#!/usr/bin/env bash
# The whole of the custom component, in the form the test needs: copy a Borg repository to Proton Drive and remove from Proton what the repository no longer has.
# Exit status: 0 only if every step worked (a systemd unit running it fails loudly otherwise).
set -euo pipefail
PD=${PD:-$HOME/ptest/pd.sh}; LOCAL=${LOCAL:-/srv/protontest/data/repo}; REMOTE=${REMOTE:-/my-files/tidepool-offsite-test/repo}; INLOCAL=/data/repo
$PD filesystem upload -f create-new-revision -d merge "$INLOCAL" "$(dirname "$REMOTE")" > /tmp/sync-up.out
cat /tmp/sync-up.out | grep -E "Uploaded|Skipped|Failed" | tr '\n' ' '; echo
remote_files() { local dir=$1 rel=$2 line type name; while IFS=$'\t' read -r type name; do
    if [ "$type" = folder ]; then remote_files "$dir/$name" "$rel$name/"; else echo "$rel$name"; fi
  done < <($PD filesystem list -j "$dir" | jq -r '.[] | [.type, .name.value] | @tsv'); }
mapfile -t gone < <(comm -13 <(cd "$LOCAL" && find . -type f | sed 's|^\./||' | sort) <(remote_files "$REMOTE" "" | sort))
for f in "${gone[@]}"; do [ -n "$f" ] || continue; echo "trash remote: $f"; $PD filesystem trash "$REMOTE/$f" > /dev/null; done
echo "synced; removed ${#gone[@]} stale remote file(s)"
