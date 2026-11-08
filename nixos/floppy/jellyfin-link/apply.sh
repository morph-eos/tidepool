#!/usr/bin/env bash
# From the workstation: point the server's Jellyfin plugins (Webhook and ListenBrainz) at Floppy for ONE person.
# Needs: that person has signed in to Floppy once (the account, and its token, exist), and the Jellyfin user's name.
# The token is read on the server from Floppy's database and goes into the plugins' files; it is never printed, and nothing is left in /tmp.
#
#   apply.sh --host SSH-NAME --url https://track.EXAMPLE.ORG --floppy-user NAME --jellyfin-user NAME [--check]
# --check resolves both names and says what it would do, without changing anything.
set -euo pipefail

host=""; fuser=""; juser=""; url=""; check=0
while [ $# -gt 0 ]; do
  case "$1" in
    --host) host="$2"; shift 2 ;;
    --floppy-user) fuser="$2"; shift 2 ;;
    --jellyfin-user) juser="$2"; shift 2 ;;
    --url) url="$2"; shift 2 ;;
    --check) check=1; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
[ -n "$host" ] && [ -n "$url" ] && [ -n "$fuser" ] && [ -n "$juser" ] || { echo "needs --host, --url, --floppy-user and --jellyfin-user" >&2; exit 2; }
re='^[A-Za-z0-9._@+-]+$'
[[ "$fuser" =~ $re ]] && [[ "$juser" =~ $re ]] || { echo "the names may hold letters, digits and . _ @ + - only" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"
stage="ff-stage-$$"

ssh "$host" "mkdir -m 700 $stage"
trap 'ssh "$host" "rm -rf $stage" >/dev/null 2>&1 || true' EXIT
scp -q "$here/configure.sh" "$here/webhook-template.hbs" "$host:$stage/"

ssh "$host" bash -s -- "$stage" "$fuser" "$juser" "$url" "$check" <<'REMOTE'
set -euo pipefail
stage="$1"; fuser="$2"; juser="$3"; url="$4"; check="$5"
work="$(sudo mktemp -d)"; sudo chmod 700 "$work"
trap 'sudo rm -rf "$work"' EXIT

# the Floppy token: read from the database (peer authentication, as the postgres user), into a file only root can read
sudo -u postgres psql -d floppy -v u="$fuser" -tAq <<SQL | sudo tee "$work/token" >/dev/null
select token from users_user where username = :'u';
SQL
if [ ! -s "$work/token" ] || [ "$(sudo tr -d '\n' < "$work/token" | wc -c)" -lt 10 ]; then
  echo "Floppy has no account named '$fuser': the person must sign in at $url once first" >&2; exit 1
fi

# the Jellyfin user's id: from a private copy of the database (the names only are read, no hash is shown)
sudo cp /srv/data/jellyfin/config/data/jellyfin.db "$work/jf.db"
guid="$(sudo nix run nixpkgs#sqlite -- -readonly "$work/jf.db" "select Id from Users where Username = '$juser' collate nocase" 2>/dev/null | head -1)"
[[ "$guid" =~ ^[0-9A-Fa-f-]{36}$ ]] || { echo "Jellyfin has no user named '$juser'" >&2; exit 1; }

echo "Floppy account '$fuser' found; Jellyfin user '$juser' is $guid; address $url"
if [ "$check" = 1 ]; then echo "(check only: nothing changed)"; exit 0; fi

sudo bash "$stage/configure.sh" --config-dir /srv/data/jellyfin/config --jellyfin-user-id "$guid" --floppy-url "$url" --token-file "$work/token"
sudo systemctl restart podman-jellyfin.service
for i in $(seq 1 40); do curl -s -m 3 -o /dev/null -f http://127.0.0.1:8096/System/Info/Public && break; sleep 3; done
echo "Jellyfin restarted"
sudo grep -h -E "Loaded plugin: \"?(Webhook|ListenBrainz)" /srv/data/jellyfin/config/log/log_"$(date +%Y%m%d)".log | tail -2 | cut -c1-150
REMOTE
