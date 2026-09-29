#!/usr/bin/env bash
# =============================================================================
# LIGHT backup of the Incus configuration (NO VM content).
#
# Exports to /mnt/nas2/incus-config-backup/ (output NOT versioned in git, covered
# by the Borg backups):
#   - global-db-dump.sql : LIVE SQL dump of the global DB (profiles, networks, storage,
#                          instance config, and the trusted dashboard/API CERTIFICATES)
#   - local-db-dump.sql  : LIVE SQL dump of the node's local DB
#   - certs/*.crt        : the trusted client certificates extracted as PEM
#   - server.crt         : the server's public cert (the private key lives in the
#                          certbot data, already included in the backups)
#   - yaml/*.yaml        : readable exports (trust, profiles, managed networks,
#                          storage, instance config) for quick restore
#
# Uses "incus admin sql ... .dump" to read the LIVE state (the db.bin files on disk
# are checkpoints lagging behind the raft log and would lose recent writes,
# e.g. new certificates).
#
# The folder lives under /mnt/nas2 -> automatically included in the "REDACTED_DRIVE" backup
# (nas2 -> nas, HDD->HDD) and added to the "offsite" backup sources
# (-> Proton Drive). Does NOT include VM disk images / storage-pools / images.
# =============================================================================
set -uo pipefail

OUT="/mnt/nas2/incus-config-backup"
LOG="/var/log/incus-config-backup.log"
INCUS="/opt/incus/bin/incus"

log() { echo "$(date -Is) - $*" >> "$LOG"; }
die() { log "ERRORE: $*"; echo "ERRORE: $*" >&2; exit 1; }

command -v sqlite3 >/dev/null || die "sqlite3 mancante"
[ -x "$INCUS" ] || die "binario incus non trovato: $INCUS"
"$INCUS" admin waitready --timeout=30 >/dev/null 2>&1 || die "daemon Incus non pronto"

mkdir -p "$OUT/certs" "$OUT/yaml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "Avvio backup config Incus -> $OUT"

# --- 1) LIVE SQL dump of the global and local DBs ---------------------------
"$INCUS" admin sql global .dump > "$OUT/global-db-dump.sql.new" 2>>"$LOG" \
    || die "dump global fallito"
[ -s "$OUT/global-db-dump.sql.new" ] || die "dump global vuoto"
mv -f "$OUT/global-db-dump.sql.new" "$OUT/global-db-dump.sql"

"$INCUS" admin sql local .dump > "$OUT/local-db-dump.sql.new" 2>>"$LOG" \
    && [ -s "$OUT/local-db-dump.sql.new" ] \
    && mv -f "$OUT/local-db-dump.sql.new" "$OUT/local-db-dump.sql" \
    || log "WARN: dump local non riuscito (non critico)"

# --- 2) Extract the trusted certificates as PEM (from a temp copy of the dump) -----
rm -f "$OUT"/certs/*.crt 2>/dev/null || true
if sqlite3 "$TMP/g.db" < "$OUT/global-db-dump.sql" 2>>"$LOG"; then
    while IFS='|' read -r name fp; do
        [ -n "$fp" ] || continue
        safe=$(echo "${name:-cert}" | tr -c 'A-Za-z0-9._-' '_')
        sqlite3 -noheader "$TMP/g.db" \
            "SELECT certificate FROM certificates WHERE fingerprint='$fp';" \
            > "$OUT/certs/${safe}-${fp:0:12}.crt" 2>>"$LOG" || true
    done < <(sqlite3 -noheader "$TMP/g.db" \
            "SELECT IFNULL(name,'')||'|'||fingerprint FROM certificates;" 2>>"$LOG")
else
    log "WARN: impossibile estrarre i PEM dal dump"
fi

# --- 3) Server public cert --------------------------------------------
[ -e /var/lib/incus/server.crt ] && cp -L /var/lib/incus/server.crt "$OUT/server.crt" 2>/dev/null || true

# --- 4) Readable YAML exports (best-effort) ---------------------------
rm -f "$OUT"/yaml/*.yaml 2>/dev/null || true
"$INCUS" config trust list -f yaml > "$OUT/yaml/trust.yaml" 2>/dev/null || true
while read -r p; do [ -n "$p" ] && "$INCUS" profile show "$p" > "$OUT/yaml/profile-$p.yaml" 2>/dev/null; done \
    < <("$INCUS" profile list -f csv -c n 2>/dev/null)
while IFS=, read -r n managed; do
    [ "$managed" = "true" ] && "$INCUS" network show "$n" > "$OUT/yaml/network-$n.yaml" 2>/dev/null
done < <("$INCUS" network list -f csv -c n,m 2>/dev/null)
while read -r s; do [ -n "$s" ] && "$INCUS" storage show "$s" > "$OUT/yaml/storage-$s.yaml" 2>/dev/null; done \
    < <("$INCUS" storage list -f csv -c n 2>/dev/null)
while read -r i; do [ -n "$i" ] && "$INCUS" config show "$i" > "$OUT/yaml/instance-$i.yaml" 2>/dev/null; done \
    < <("$INCUS" list -f csv -c n 2>/dev/null)

SIZE=$(du -sh "$OUT" 2>/dev/null | cut -f1)
NCERT=$(find "$OUT"/certs -name '*.crt' 2>/dev/null | wc -l)
log "Completato. Dimensione=$SIZE, certificati=$NCERT"
echo "Backup config Incus completato in $OUT (size=$SIZE, certs=$NCERT)"
exit 0
