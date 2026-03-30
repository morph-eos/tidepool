#!/usr/bin/env bash
set -euo pipefail

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

borg create --progress --stats --compression lz4 --checkpoint-interval 300 "${REPO}::${ARCHIVE}" "${SOURCE}"
borg prune --list --keep-daily=7 --keep-weekly=4 --keep-monthly=6 "${REPO}"
borg compact "${REPO}"

echo "$(date -Is) - Backup done: ${ARCHIVE}"
