#!/usr/bin/env bash
# lab/v0-replica/seed.sh — start the v0 replica (docker-compose.yml here) and fill every service with data through its own API, then write what the migration must preserve to /root/v0-state.json.
# Runs INSIDE the v0 VM as root, with the compose file in /srv/v0/ and generated pictures in /tmp/imgs/a. Lab scaffolding.
set -uo pipefail
cd /srv/v0
say() { echo "$(date +%H:%M:%S) $*"; }
mkdir -p data/immich/library data/immich/postgres data/jellyfin/config data/jellyfin/cache data/vaultwarden data/webdav data/syncthing data/nextcloud/{html,data,db} media media2
chown -R 1000:1000 data/jellyfin data/syncthing
docker compose up -d 2>&1 | tail -n 3
S=/root/v0-state.json; echo '{}' > $S
setj() { jq --arg k "$1" --arg v "$2" '.[$k]=$v' $S > $S.tmp && mv $S.tmp $S; }
say "waiting for the services"
for i in $(seq 1 90); do curl -sf http://127.0.0.1:2283/api/server/ping >/dev/null && curl -sf http://127.0.0.1:8222/alive >/dev/null && curl -sf -H 'Host: localhost' http://127.0.0.1:8080/status.php | grep -q '"installed":true' && curl -sf http://127.0.0.1:8096/health >/dev/null && break; sleep 5; done
say "== Immich"
bash /tmp/immich-seed.sh http://127.0.0.1:2283 /tmp/imgs/a | tail -n 1
tok=$(curl -sf -H 'Content-Type: application/json' -X POST http://127.0.0.1:2283/api/auth/login -d '{"email":"lab@example.com","password":"lab-only-password"}' | jq -r .accessToken)
setj immich_assets "$(curl -sf -H "Authorization: Bearer $tok" http://127.0.0.1:2283/api/server/statistics | jq -r .photos)"
curl -sf -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -X POST http://127.0.0.1:2283/api/search/metadata -d '{"size":1000}' | jq -r '.assets.items[].id' | sort > /root/v0-immich-ids.txt
say "== Nextcloud (MariaDB)"
NC() { curl -s -H 'Host: localhost' -u admin:v0adminpass "$@"; }
docker exec -u www-data nextcloud php occ user:add --password-from-env --display-name Alice alice <<< "" >/dev/null 2>&1 || OC_PASS=v0alicepass docker exec -e OC_PASS=v0alicepass -u www-data nextcloud php occ user:add --password-from-env --display-name Alice alice 2>&1 | tail -n 1
for n in 1 2 3; do echo "nextcloud file $n" | NC -T - http://127.0.0.1:8080/remote.php/dav/files/admin/doc$n.txt -o /dev/null; done
NC -X MKCOL http://127.0.0.1:8080/remote.php/dav/files/admin/Photos >/dev/null; head -c 300000 /dev/urandom | NC -T - http://127.0.0.1:8080/remote.php/dav/files/admin/Photos/random.bin -o /dev/null
echo "alice's file" | curl -s -H 'Host: localhost' -u alice:v0alicepass -T - http://127.0.0.1:8080/remote.php/dav/files/alice/alice.txt -o /dev/null
SH=$(NC -H 'OCS-APIRequest: true' -H 'Accept: application/json' -X POST http://127.0.0.1:8080/ocs/v2.php/apps/files_sharing/api/v1/shares -d 'path=/doc1.txt&shareType=3' | jq -r '.ocs.data.token')
docker exec -u www-data nextcloud php occ config:app:set migrationtest marker --value=v0-before >/dev/null
docker exec nextcloud sh -c 'grep -E "instanceid|passwordsalt|.secret.|dbtype|version" /var/www/html/config/config.php' | sed -E "s/ +/ /g" > /root/v0-nc-config.txt
setj nc_share_token "$SH"; setj nc_version "$(docker exec -u www-data nextcloud php occ status | grep -E '^\s*- version:' | awk '{print $3}')"
setj nc_md5 "$(cd data/nextcloud/data && find . -type f -path '*files/*' -print0 | LC_ALL=C sort -z | xargs -0 md5sum | md5sum | cut -d' ' -f1)"
say "nextcloud: $(docker exec -u www-data nextcloud php occ user:list | tr '\n' ' ') version $(jq -r .nc_version $S), a public share token $SH"
say "== Vaultwarden (SQLite)"
python3 - <<'P'
import base64,hashlib,json,urllib.request,uuid
B="http://127.0.0.1:8222"
email="lab@example.com"; pw="v0-vault-master"
mk=hashlib.pbkdf2_hmac('sha256',pw.encode(),email.encode(),600000,32)
mph=base64.b64encode(hashlib.pbkdf2_hmac('sha256',mk,pw.encode(),1,32)).decode()
enc=lambda: "2."+base64.b64encode(b"0123456789abcdef").decode()+"|"+base64.b64encode(b"x"*48).decode()+"|"+base64.b64encode(b"m"*32).decode()
def post(path,data,headers=None,form=False):
    h={"Content-Type":"application/x-www-form-urlencoded" if form else "application/json"}; h.update(headers or {})
    body=urllib.parse.urlencode(data).encode() if form else json.dumps(data).encode()
    r=urllib.request.Request(B+path,body,h); 
    try: return json.loads(urllib.request.urlopen(r).read() or b"{}")
    except urllib.error.HTTPError as e: print("HTTP",e.code,path,e.read()[:200]); return {}
import urllib.parse
post("/identity/accounts/register",{"email":email,"masterPasswordHash":mph,"masterPasswordHint":"","name":"Lab","key":enc(),"keys":{"publicKey":base64.b64encode(b"p"*100).decode(),"encryptedPrivateKey":enc()},"kdf":0,"kdfIterations":600000})
tok=post("/identity/connect/token",{"grant_type":"password","username":email,"password":mph,"scope":"api offline_access","client_id":"web","deviceType":"9","deviceIdentifier":str(uuid.uuid4()),"deviceName":"lab"},{"Auth-Email":base64.urlsafe_b64encode(email.encode()).decode().rstrip("=")},form=True)
t=tok.get("access_token"); print("vaultwarden login:", "ok" if t else "FAILED")
if t:
    for n in range(3): post("/api/ciphers",{"type":1,"name":enc(),"login":{"username":enc(),"password":enc(),"uris":[]},"notes":None,"favorite":False},{"Authorization":"Bearer "+t})
    sync=json.loads(urllib.request.urlopen(urllib.request.Request(B+"/api/sync",headers={"Authorization":"Bearer "+t})).read()); print("vaultwarden ciphers:",len(sync["ciphers"]))
    open("/root/v0-vw-ciphers.txt","w").write(str(len(sync["ciphers"])))
P
setj vw_ciphers "$(cat /root/v0-vw-ciphers.txt 2>/dev/null)"; setj vw_rsa "$(sha256sum data/vaultwarden/rsa_key.pem | cut -d' ' -f1)"; setj vw_users "$(sqlite3 data/vaultwarden/db.sqlite3 'select count(*) from users' 2>/dev/null || echo ?)"
say "== WebDAV"
for n in 1 2 3; do echo "webdav file $n" | curl -s -u seedvault:v0davpass -T - http://127.0.0.1:8280/seedvault/w$n.txt -o /dev/null; done; curl -s -u seedvault:v0davpass -X MKCOL http://127.0.0.1:8280/seedvault/ >/dev/null; for n in 1 2 3; do echo "webdav file $n" | curl -s -u seedvault:v0davpass -T - http://127.0.0.1:8280/seedvault/w$n.txt -o /dev/null; done; head -c 5000000 /dev/urandom | curl -s -u seedvault:v0davpass -T - http://127.0.0.1:8280/seedvault/big.bin -o /dev/null
say "webdav files: $(find data/webdav -type f | wc -l); the container's password file: $(docker exec webdav sh -c 'ls /user.passwd /etc/apache2/*passwd* /usr/local/apache2/conf/*.passwd 2>/dev/null' | tr '\n' ' ')"
setj webdav_files "$(find data/webdav -type f | wc -l)"; setj webdav_md5 "$(cd data/webdav && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum | md5sum | cut -d' ' -f1)"
say "== Syncthing"
for i in $(seq 1 30); do [ -f data/syncthing/config/config.xml ] && break; sleep 2; done
KEY=$(grep -o '<apikey>[^<]*' data/syncthing/config/config.xml | cut -d'>' -f2)
curl -sf -H "X-API-Key: $KEY" -H 'Content-Type: application/json' -X POST http://127.0.0.1:8384/rest/config/folders -d '{"id":"labfolder","label":"Lab","path":"/var/syncthing/Sync","type":"sendreceive"}' >/dev/null
echo "synced content" > data/syncthing/Sync/file.txt 2>/dev/null || { mkdir -p data/syncthing/Sync; chown 1000:1000 data/syncthing/Sync; echo "synced content" > data/syncthing/Sync/file.txt; chown 1000:1000 data/syncthing/Sync/file.txt; }
sleep 5; setj st_device "$(curl -sf -H "X-API-Key: $KEY" http://127.0.0.1:8384/rest/system/status | jq -r .myID)"; setj st_folders "$(curl -sf -H "X-API-Key: $KEY" http://127.0.0.1:8384/rest/config/folders | jq -r '[.[].id]|join(",")')"
say "syncthing: device $(jq -r .st_device $S | cut -c1-14)..., folders $(jq -r .st_folders $S)"
say "== Jellyfin"
J=http://127.0.0.1:8096
jp() { curl -sf -H 'Content-Type: application/json' -H 'Authorization: MediaBrowser Client="lab", Device="lab", DeviceId="lab", Version="1.0"' "$@"; }   # Jellyfin 12 reads Authorization; X-Emby-Authorization is refused
jp -X POST $J/Startup/Configuration -d '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' >/dev/null
jp $J/Startup/User >/dev/null; jp -X POST $J/Startup/User -d '{"Name":"jelly","Password":"v0jellypass"}' >/dev/null
jp -X POST $J/Startup/Complete >/dev/null
AUTHJ=$(jp -X POST $J/Users/AuthenticateByName -d '{"Username":"jelly","Pw":"v0jellypass"}' | jq -r .AccessToken)
jq2() { curl -sf -H "Authorization: MediaBrowser Client=\"lab\", Device=\"lab\", DeviceId=\"lab\", Version=\"1.0\", Token=\"$AUTHJ\"" -H 'Content-Type: application/json' "$@"; }
echo "x" > media/readme.txt
jq2 -X POST "$J/Library/VirtualFolders?name=Movies&collectionType=movies&refreshLibrary=false" -d '{"LibraryOptions":{"PathInfos":[{"Path":"/media"}]}}' >/dev/null
jq2 -X POST "$J/Library/VirtualFolders?name=Shows&collectionType=tvshows&refreshLibrary=false" -d '{"LibraryOptions":{"PathInfos":[{"Path":"/media2"}]}}' >/dev/null
jq2 -X POST $J/Users/New -d '{"Name":"kid","Password":"v0kidpass"}' >/dev/null
setj jf_users "$(jq2 $J/Users | jq -r '[.[].Name]|sort|join(",")')"; setj jf_libs "$(jq2 $J/Library/VirtualFolders | jq -r '[.[]|"\(.Name)=\(.Locations[0])"]|sort|join(",")')"
say "jellyfin: users $(jq -r .jf_users $S); libraries $(jq -r .jf_libs $S)"
say "state: $(cat $S | jq -c .)"
