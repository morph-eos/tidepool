#!/usr/bin/env bash
set -euo pipefail

# Unencrypted REDACTED_DRIVE repo: allow access without a prompt (it was inherited from cron.d)
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes

REPO="/mnt/nas/backup/REDACTED_DRIVE"
SOURCE="/mnt/nas2"
HOSTNAME="$(hostname -s)"
DATE="$(date +%Y-%m-%d_%H-%M)"
ARCHIVE="${HOSTNAME}-${DATE}"

if ! mountpoint -q "${SOURCE}"; then
	echo "$(date -Is) - Backup skipped: ${SOURCE} not mounted." >&2
	exit 0
fi

if ! mountpoint -q "/mnt/nas"; then
	echo "$(date -Is) - Backup skipped: /mnt/nas not mounted." >&2
	exit 0
fi

if ! [ -d "${REPO}" ]; then
	echo "$(date -Is) - Backup skipped: repo missing at ${REPO}." >&2
	exit 0
fi

echo "$(date -Is) - Backup start: ${SOURCE} -> ${REPO} (${ARCHIVE})"

# rc 1 = warning (e.g. files changed during the copy, normal on live data): not an error.
# Only rc >= 2 aborts, so prune and compact still run.
BORG_RC=0
borg create --progress --stats --compression lz4 --checkpoint-interval 300 "${REPO}::${ARCHIVE}" "${SOURCE}" || BORG_RC=$?
if [ "$BORG_RC" -ge 2 ]; then
	echo "$(date -Is) - Backup FAILED: borg create exit code ${BORG_RC}" >&2
	exit "$BORG_RC"
fi
[ "$BORG_RC" -eq 1 ] && echo "$(date -Is) - WARN: borg create terminato con warning (exit 1)"
borg prune --list --keep-daily=7 --keep-weekly=4 --keep-monthly=6 "${REPO}"
borg compact "${REPO}"

echo "$(date -Is) - Backup done: ${ARCHIVE}"
