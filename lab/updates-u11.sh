#!/usr/bin/env bash
# =============================================================================
# lab/updates-u11.sh — phase 8 follow-up (ADR 0016), U11: the way out of a NixOS module. Nextcloud, which the module runs, is started from the OFFICIAL container image on the SAME data
# and the SAME PostgreSQL database, to measure what leaving the module costs. Runs INSIDE the lab host as root. Nothing of the module's state is modified: the container works on a copy.
# =============================================================================
set -uo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH
ms() { echo $(( $(date +%s%N) / 1000000 )); }
say() { echo "$(date +%H:%M:%S) $*"; }
NC=/srv/data/nextcloud; T=/srv/data/nc-container
NCPASS=$(cat /run/secrets/nextcloud-admin-pass)
files() { local base=$1; shift; curl -sk -m 10 "$@" -u root:$NCPASS -X PROPFIND -H 'Depth: 1' "$base/remote.php/dav/files/root/" | grep -o 'nc-[ab][0-9].txt' | sort -u | wc -l; }
say "module: $(curl -sk --resolve cloud.lab.test:443:127.0.0.1 https://cloud.lab.test/status.php | jq -c '{version:.versionstring}'); test files seen: $(files https://cloud.lab.test --resolve cloud.lab.test:443:127.0.0.1)"
S=$(ms)
say "1. stop the module's services (the container will take their place)"; systemctl stop phpfpm-nextcloud nextcloud-cron.timer nextcloud-update-db nextcloud-setup 2>&1 | tail -n 1
say "2. the state to carry over: config/, data/, apps; size on disk: $(du -sh $NC | cut -f1); the module keeps nothing else (the database is in PostgreSQL)"
rm -rf $T; cp -a $NC $T
say "3. a new config.php for the container: keep the identity (instanceid, salt, secret), the database and the data path; drop the module's Nix-store paths"
python3 - <<'PY'
import re
s=open("/srv/data/nc-container/config/config.php").read()
s=re.sub(r"  'apps_paths' =>.*?\n  \),\n  'appstoreenabled'", "  'appstoreenabled'", s, flags=re.S)
s=re.sub(r"  'default_certificates_bundle_path'[^\n]*\n","",s)
s=s.replace("'datadirectory' => '/srv/data/nextcloud/data'","'datadirectory' => '/var/www/html/data'")
s=s.replace("'appstoreenabled' => false","'appstoreenabled' => true")
open("/srv/data/nc-container/config/config.php","w").write(s)
PY
rm -f $T/config/override.config.php
say "   the module also generated settings from its options (the trusted domain, the https setting) in a Nix-store JSON file; they have to be stated again for the container"
cat > $T/config/tidepool.config.php <<'PHP'
<?php
$CONFIG = [ 'trusted_domains' => [ 'cloud.lab.test', 'localhost' ], 'overwriteprotocol' => 'https', 'overwrite.cli.url' => 'https://cloud.lab.test' ];
PHP
grep -c "nix/store" $T/config/config.php | sed 's/^/   nix-store references left in the new config: /'
say "4. the image"; s=$(ms); podman pull -q docker.io/library/nextcloud:33-apache >/dev/null 2>&1; say "   pulled in $(( ($(ms) - s) / 1000 )) s: $(podman image exists docker.io/library/nextcloud:33-apache && echo yes || echo NO)"
UID_NC=$(id -u nextcloud); GID_NC=$(id -g nextcloud)
say "5. run it as the host's own nextcloud user ($UID_NC:$GID_NC), so that the database login by Unix socket (peer authentication) keeps working with no password and no new database setting"
say "   (the image listens on port 80 and a non-root user cannot: two small files replace Apache's ports.conf and default site, a detail of the official image)"
mkdir -p /srv/data/nc-ap; echo "Listen 8088" > /srv/data/nc-ap/ports.conf
podman run --rm docker.io/library/nextcloud:33-apache cat /etc/apache2/sites-enabled/000-default.conf | sed 's/:80>/:8088>/' > /srv/data/nc-ap/000-default.conf
podman rm -f nc-c >/dev/null 2>&1
podman run -d --name nc-c --network=host --user $UID_NC:$GID_NC \
  -v /srv/data/nc-ap/ports.conf:/etc/apache2/ports.conf:ro -v /srv/data/nc-ap/000-default.conf:/etc/apache2/sites-enabled/000-default.conf:ro \
  -v $T:/var/www/html -v /run/postgresql:/run/postgresql -v /run/redis-nextcloud:/run/redis-nextcloud docker.io/library/nextcloud:33-apache >/dev/null 2>/tmp/nc-run.err; cat /tmp/nc-run.err | head -n 3
ok=no; for i in $(seq 1 30); do curl -s -m 3 -H 'Host: cloud.lab.test' http://127.0.0.1:8088/status.php | jq -e .installed >/dev/null 2>&1 && { ok=yes; break; }; sleep 3; done
say "   the container answers: $ok after $(( ($(ms) - S) / 1000 )) s since step 1"
podman logs nc-c 2>&1 | grep -iE "error|fail|denied|cannot|unable|upgrad|init|mismatch|refus" | head -n 8 | cut -c1-200
say "6. what it sees: $(curl -s -m 5 -H 'Host: cloud.lab.test' http://127.0.0.1:8088/status.php | jq -c '{installed,maintenance,needsDbUpgrade,version:.versionstring}' 2>&1 | head -c 150)"
say "   status.php through the container, raw: $(curl -s -m 5 -H 'Host: cloud.lab.test' http://127.0.0.1:8088/status.php | head -c 160 | tr '\n' ' ')"
say "   the same test files through the container: $(files http://127.0.0.1:8088 -H 'Host: cloud.lab.test') of 5; one file's content: $(curl -s -m 5 -u root:$NCPASS -H 'Host: cloud.lab.test' http://127.0.0.1:8088/remote.php/dav/files/root/nc-a1.txt | head -c 40)"
say "   the OIDC app (installed by the module from the Nix store): $(podman exec nc-c php occ app:list 2>/dev/null | grep -c oidc) mention(s) in the container"
say "7. what the container's database login looks like: $(runuser -u nextcloud -- psql -d nextcloud -h /run/postgresql -Atc 'select count(*) from oc_filecache' 2>&1 | head -n 1)"
say "total from stopping the module to the container serving the same data: $(( ($(ms) - S) / 1000 )) s; units failed: $(systemctl --failed --no-legend | wc -l)"
podman rm -f nc-c >/dev/null 2>&1; rm -rf $T /srv/data/nc-ap
systemctl start nextcloud-setup phpfpm-nextcloud nextcloud-cron.timer 2>&1 | tail -n 1; sleep 8
say "the module is back: $(curl -sk --resolve cloud.lab.test:443:127.0.0.1 https://cloud.lab.test/status.php | jq -c '{version:.versionstring}')"
