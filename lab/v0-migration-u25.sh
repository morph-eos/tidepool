#!/usr/bin/env bash
# =============================================================================
# lab/v0-migration-u25.sh <prep|immich|nextcloud|vaultwarden|webdav|syncthing|jellyfin|start|verify|all> — the move from v0 to the new host, rehearsed on a REPLICA of v0 (VM "v0": the same images and
# container-side paths as v0's docker-compose.yml, filled by lab/v0-replica/seed.sh) and the lab host "host-m" (the flake's `lab` host plus lab/v0-replica/migration-test.nix).
# The real v0 machine is never touched. Runs on the WORKSTATION. What each stage does is what the real cutover does, with the real paths in place of the lab's.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; VM="$HERE/vm.sh"; W=/tmp/v0mig; mkdir -p "$W"
V0() { "$VM" ssh v0 "$@"; }
NEW() { "$VM" ssh host-m "$@"; }
say() { echo "$(date +%H:%M:%S) $*"; }
put() { cat "$1" | NEW "cat > $2"; }                        # a file from the workstation onto the new host
ENVR='export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH NIX_CONFIG="experimental-features = nix-command flakes
download-attempts = 60"'
stage_prep() {
    say "== prep: v0 stays up until its dumps are taken; the new host's services stop"
    NEW "$ENVR; sudo systemctl stop nginx phpfpm-nextcloud nextcloud-cron.timer nextcloud-cron vaultwarden podman-immich-server podman-immich-redis podman-jellyfin syncthing prometheus alertmanager 2>/dev/null; echo stopped"
    V0 'sudo cat /root/v0-state.json' > "$W/state.json"; say "v0's recorded state: $(jq -c . "$W/state.json" | cut -c1-200)"
}
stage_immich() {
    say "== Immich: pg_dump of v0's PostgreSQL 14, restored into the native 17 (ADR 0006's documented procedure), the library copied"
    V0 'sudo docker exec immich_postgres pg_dump --clean --if-exists --username=postgres immich | gzip' > "$W/immich.sql.gz"; say "dump: $(du -h "$W/immich.sql.gz" | cut -f1)"
    put "$W/immich.sql.gz" /tmp/immich.sql.gz
    NEW "$ENVR; sudo systemctl stop podman-immich-server podman-immich-redis 2>/dev/null
      gunzip < /tmp/immich.sql.gz | sed \"s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g\" | sudo -u postgres psql --dbname=immich --single-transaction -v ON_ERROR_STOP=on -q 2>&1 | tail -n 3; echo \"restore exit: \${PIPESTATUS[1]}\"
      sudo rm -rf /srv/data/immich/upload; sudo mkdir -p /srv/data/immich/upload"
    s=$(date +%s); V0 'sudo tar -C /srv/v0/data/immich/library -cf - .' | NEW 'sudo tar -C /srv/data/immich/upload -xpf -'; say "library copied in $(( $(date +%s) - s )) s: $(NEW 'sudo find /srv/data/immich/upload -type f | wc -l') files"
}
stage_nextcloud() {
    say "== Nextcloud: MariaDB converted to PostgreSQL by occ db:convert-type on v0 (into a temporary PostgreSQL container), dumped, restored into the native PostgreSQL; the data directory and config.php copied"
    V0 'sudo bash -s' <<'R'
cd /srv/v0
cp data/nextcloud/html/config/config.php /root/config.php.v0
docker exec -u www-data nextcloud php occ maintenance:mode --on | tail -n 1
docker rm -f ncpg >/dev/null 2>&1
docker run -d --name ncpg --network v0_default -e POSTGRES_USER=nextcloud -e POSTGRES_PASSWORD=migrate -e POSTGRES_DB=nextcloud postgres:17-alpine >/dev/null
for i in $(seq 1 40); do docker exec ncpg pg_isready -U nextcloud -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 2; done
s=$(date +%s); docker exec -u www-data nextcloud php occ db:convert-type --all-apps --clear-schema --password=migrate --port=5432 --no-interaction pgsql nextcloud ncpg nextcloud 2>&1 | tail -n 4; echo "convert-type: $(( $(date +%s) - s )) s"
docker exec ncpg pg_dump -U nextcloud --no-owner --no-acl nextcloud | gzip > /tmp/nc.sql.gz; ls -la /tmp/nc.sql.gz | awk '{print "dump:", $5, "bytes"}'
R
    V0 'sudo cat /tmp/nc.sql.gz' > "$W/nc.sql.gz"; V0 'sudo cat /root/config.php.v0' > "$W/config.php.v0"
    put "$W/nc.sql.gz" /tmp/nc.sql.gz; put "$W/config.php.v0" /tmp/config.php.v0
    NEW "$ENVR; sudo systemctl stop phpfpm-nextcloud nextcloud-cron.timer 2>/dev/null
      sudo -u postgres psql -qc 'DROP DATABASE IF EXISTS nextcloud' -c 'CREATE DATABASE nextcloud OWNER nextcloud' 2>&1 | tail -n 2
      (echo 'SET ROLE nextcloud;'; gunzip < /tmp/nc.sql.gz) | sudo -u postgres psql --dbname=nextcloud --single-transaction -v ON_ERROR_STOP=on -q 2>&1 | tail -n 3; echo \"restore exit: \${PIPESTATUS[1]}\"
      sudo rm -rf /srv/data/nextcloud/data; sudo mkdir -p /srv/data/nextcloud/data /srv/data/nextcloud/config"
    s=$(date +%s); V0 'sudo tar -C /srv/v0/data/nextcloud/data -cf - .' | NEW 'sudo tar -C /srv/data/nextcloud/data -xpf -'; say "data copied in $(( $(date +%s) - s )) s"
    NEW "sudo cp /tmp/config.php.v0 /srv/data/nextcloud/config/config.php; sudo chown -R nextcloud:nextcloud /srv/data/nextcloud/data /srv/data/nextcloud/config; echo 'config.php and ownership in place'"
}
stage_vaultwarden() {
    say "== Vaultwarden: the new instance creates the schema on PostgreSQL, is stopped, then pgloader moves the data (the project's documented way); the key and attachments are copied"
    V0 'sudo docker stop vaultwarden >/dev/null; sudo sqlite3 /srv/v0/data/vaultwarden/db.sqlite3 "PRAGMA journal_mode=delete;" >/dev/null; sudo cat /srv/v0/data/vaultwarden/db.sqlite3' > "$W/vw.sqlite3"; V0 'sudo tar -C /srv/v0/data/vaultwarden --exclude=db.sqlite3 --exclude="db.sqlite3-*" --exclude=vaultwarden.log -cf - .' > "$W/vw-files.tar"
    put "$W/vw.sqlite3" /tmp/vw.sqlite3; put "$W/vw-files.tar" /tmp/vw-files.tar
    NEW "$ENVR; sudo -u postgres psql -qd vaultwarden -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION vaultwarden' >/dev/null; sudo systemctl start vaultwarden; for i in \$(seq 1 40); do curl -sf http://127.0.0.1:8222/alive >/dev/null && break; sleep 2; done; sudo systemctl stop vaultwarden
      echo \"schema made by the new instance: \$(sudo -u postgres psql -d vaultwarden -Atc \"select count(*) from information_schema.tables where table_schema='public'\") tables\"
      sudo rm -rf /tmp/pgloader; sudo install -d -o vaultwarden /tmp/pgl; cat > /tmp/bitwarden.load <<'N'
load database
     from sqlite:///tmp/vw.sqlite3
     into postgresql://vaultwarden@unix:/run/postgresql:/vaultwarden
     WITH data only, include no drop, reset sequences
     EXCLUDING TABLE NAMES LIKE '__diesel_schema_migrations'
;
N
      PGL=\$(nix build nixpkgs#pgloader --no-link --print-out-paths); sudo -u vaultwarden env HOME=/tmp/pgl \$PGL/bin/pgloader /tmp/bitwarden.load 2>&1 | tail -n 12 | cut -c1-170"
}
stage_vaultwarden_files() {
    NEW "sudo tar -C /var/lib/vaultwarden -xpf /tmp/vw-files.tar; sudo chown -R vaultwarden:vaultwarden /var/lib/vaultwarden; sudo ls /var/lib/vaultwarden | tr '\n' ' '"
}
stage_webdav() {
    say "== WebDAV: the files copied; the password file's format compared with what nginx accepts"
    V0 'sudo tar -C /srv/v0/data/webdav -cf - .' | NEW 'sudo tar -C /srv/data/webdav -xpf -'; NEW 'sudo chown -R nginx:nginx /srv/data/webdav; sudo find /srv/data/webdav -type f | wc -l'
    V0 'sudo docker exec webdav cat /user.passwd' > "$W/user.passwd"; say "v0's password file: $(sed -E 's/(:.{0,6}).*/\1.../' "$W/user.passwd" | head -2 | tr '\n' ' ')   (format of the hash: $(head -c 12 "$W/user.passwd" | sed 's/^[^:]*://' | cut -c1-6))"
}
stage_syncthing() {
    say "== Syncthing: the device keeps its identity (certificate and key as sops secrets, already in the lab host's secrets), the folder's files and the folder's index are copied"
    V0 'sudo docker stop syncthing >/dev/null; sudo tar -C /srv/v0/data/syncthing --exclude=config -cf - .' | NEW 'sudo mkdir -p /srv/data/syncthing; sudo tar -C /srv/data/syncthing -xpf -'
    NEW 'sudo chown -R syncthing:syncthing /srv/data/syncthing 2>/dev/null; sudo ls /srv/data/syncthing | tr "\n" " "'
}
stage_jellyfin() {
    say "== Jellyfin: the configuration directory copied; the libraries keep their paths because the container has the same two media mounts"
    V0 'sudo docker stop jellyfin >/dev/null; sudo tar -C /srv/v0/data/jellyfin/config -cf - .' | NEW 'sudo mkdir -p /srv/data/jellyfin/config; sudo rm -rf /srv/data/jellyfin/config/*; sudo tar -C /srv/data/jellyfin/config -xpf -'
    V0 'sudo tar -C /srv/v0/media -cf - .' | NEW 'sudo tar -C /srv/data/media -xpf -'; NEW 'sudo ls /srv/data/jellyfin/config | tr "\n" " "'
}
stage_start() {
    say "== start everything on the new host"
    NEW "$ENVR; sudo systemctl start postgresql; sudo systemctl restart nextcloud-setup 2>&1 | tail -n 2; sudo systemctl start phpfpm-nextcloud nextcloud-cron.timer nginx vaultwarden podman-immich-redis podman-immich-server podman-jellyfin syncthing 2>&1 | tail -n 3
      sleep 25; echo \"failed units: \$(systemctl --failed --no-legend | tr -s ' ' | cut -d' ' -f2 | tr '\n' ' ')\""
}
stage_verify() {
    say "== verify: what v0 recorded against what the new host answers"
    V0 'sudo bash -c "cd /srv/v0/data/nextcloud/data && find . -type f -path \"*files/*\" -print0 | LC_ALL=C sort -z | xargs -0 md5sum | md5sum; cd /srv/v0/data/webdav && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum | md5sum"' | cut -d' ' -f1 > "$W/md5s.txt"   # v0's hashes again with the C locale (the seed's first run sorted by the user's locale)
    jq --arg a "$(sed -n 1p "$W/md5s.txt")" --arg b "$(sed -n 2p "$W/md5s.txt")" '.nc_md5=$a|.webdav_md5=$b' "$W/state.json" > "$W/state2.json"; mv "$W/state2.json" "$W/state.json"
    jq -r 'to_entries[]|"\(.key)=\(.value)"' "$W/state.json" > "$W/expect.env"; put "$W/expect.env" /tmp/expect.env
    NEW 'bash -s' <<'R' 2>&1 | cut -c1-200
set -u; . /tmp/expect.env; ok=0; bad=0
chk() { if [ "$2" = "$3" ]; then echo "  ok   $1: $3" | cut -c1-120; ok=$((ok+1)); else echo "  FAIL $1: expected [$2] got [$3]"; bad=$((bad+1)); fi; }
tok=$(curl -sf -H 'Content-Type: application/json' -X POST http://127.0.0.1:2283/api/auth/login -d '{"email":"lab@example.com","password":"lab-only-password"}' | jq -r .accessToken)
chk immich_assets "$immich_assets" "$(curl -sf -H "Authorization: Bearer $tok" http://127.0.0.1:2283/api/server/statistics | jq -r .photos)"
chk nc_version "$nc_version" "$(sudo nextcloud-occ status | awk '/- version:/{print $3}')"
chk nc_share_token "$nc_share_token" "$(sudo -u postgres psql -d nextcloud -Atc "select token from oc_share limit 1")"
chk nc_md5 "$nc_md5" "$(sudo bash -c "cd /srv/data/nextcloud/data && find . -type f -path '*files/*' -print0 | LC_ALL=C sort -z | xargs -0 md5sum | md5sum" | cut -d' ' -f1)"
chk nc_login_and_file "200" "$(curl -s -o /dev/null -w '%{http_code}' -k -u alice:v0alicepass --resolve cloud.lab.test:443:127.0.0.1 https://cloud.lab.test/remote.php/dav/files/alice/alice.txt 2>/dev/null)"
chk vw_rsa "$vw_rsa" "$(sudo sha256sum /var/lib/vaultwarden/rsa_key.pem | cut -d' ' -f1)"
chk vw_users "$vw_users" "$(sudo -u postgres psql -d vaultwarden -Atc 'select count(*) from users')"
chk vw_ciphers "$vw_ciphers" "$(sudo -u postgres psql -d vaultwarden -Atc 'select count(*) from ciphers')"
chk webdav_files "$webdav_files" "$(sudo find /srv/data/webdav -type f | wc -l)"
chk webdav_md5 "$webdav_md5" "$(sudo bash -c "cd /srv/data/webdav && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum | md5sum" | cut -d' ' -f1)"
K=$(sudo sed -n 's:.*<apikey>\(.*\)</apikey>.*:\1:p' /srv/data/syncthing/.config/syncthing/config.xml)
chk st_device "$st_device" "$(curl -sf -H "X-API-Key: $K" http://127.0.0.1:8384/rest/system/status | jq -r .myID)"
chk st_folders "$st_folders" "$(curl -sf -H "X-API-Key: $K" http://127.0.0.1:8384/rest/config/folders | jq -r '[.[].id]|join(",")')"
J=http://127.0.0.1:8096; A='MediaBrowser Client="lab", Device="lab", DeviceId="lab", Version="1.0"'
T=$(curl -sf -H "Authorization: $A" -H 'Content-Type: application/json' -X POST $J/Users/AuthenticateByName -d '{"Username":"jelly","Pw":"v0jellypass"}' | jq -r .AccessToken)
chk jf_users "$jf_users" "$(curl -sf -H "Authorization: $A, Token=\"$T\"" $J/Users | jq -r '[.[].Name]|sort|join(",")')"
chk jf_libs "$jf_libs" "$(curl -sf -H "Authorization: $A, Token=\"$T\"" $J/Library/VirtualFolders | jq -r '[.[]|"\(.Name)=\(.Locations[0])"]|sort|join(",")')"
echo "verify: $ok ok, $bad failed"
R
}
case "${1:?stage}" in
verify) stage_verify ;;
prep) stage_prep ;; immich) stage_immich ;; nextcloud) stage_nextcloud ;; vaultwarden) stage_vaultwarden; stage_vaultwarden_files ;; webdav) stage_webdav ;; syncthing) stage_syncthing ;; jellyfin) stage_jellyfin ;;
start) stage_start ;; all) stage_prep; stage_immich; stage_nextcloud; stage_vaultwarden; stage_vaultwarden_files; stage_webdav; stage_syncthing; stage_jellyfin; stage_start; stage_verify ;;
esac
