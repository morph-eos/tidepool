#!/usr/bin/env bash
# lab/immich-seed.sh — fill an Immich instance with generated pictures through its API, and print what the server reports. Lab scaffolding, not part of the system.
# Usage: immich-seed.sh <base-url> <dir-with-jpgs> [count-only]   Credentials are lab-only and come from IMMICH_LAB_EMAIL / IMMICH_LAB_PASSWORD (defaults below).
set -euo pipefail
BASE=${1:?base url}; DIR=${2:?dir}; MODE=${3:-seed}
EMAIL=${IMMICH_LAB_EMAIL:-lab@example.com}; PW=${IMMICH_LAB_PASSWORD:-lab-only-password}
j() { curl -sf -H 'Content-Type: application/json' "$@"; }
if [ "$MODE" = seed ]; then
    j -X POST "$BASE/api/auth/admin-sign-up" -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\",\"name\":\"Lab\"}" >/dev/null || echo "(admin already exists)"
fi
TOKEN=$(j -X POST "$BASE/api/auth/login" -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\"}" | jq -r .accessToken)
AUTH=(-H "Authorization: Bearer $TOKEN")
if [ "$MODE" = seed ]; then
    for f in "$DIR"/*.jpg; do
        id=$(basename "$f"); ts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z -r "$f")
        curl -sf "${AUTH[@]}" -F "assetData=@$f" -F "deviceAssetId=$id" -F deviceId=lab -F "fileCreatedAt=$ts" -F "fileModifiedAt=$ts" "$BASE/api/assets" | jq -c '{id,status}'
    done
fi
echo "assets: $(curl -sf "${AUTH[@]}" "$BASE/api/server/statistics" | jq -c '{photos,videos,usage}')"
