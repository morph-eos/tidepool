#!/usr/bin/env bash
# Point Jellyfin's two plugins at Floppy, for one Jellyfin user (what the plugins' pages would do, written as the files they keep):
#   - Webhook (the official one): films and episodes -> https://track.<domain>/webhook/jellyfin/<token>, with the template Floppy gives
#   - ListenBrainz (lyarenei): music listens -> Floppy's ListenBrainz-compatible address, with the same token
# Only the chosen Jellyfin user is sent: the server has other people on it.
# The token is read from a file (or the Floppy database, see apply.sh) and never printed. Run it as root with Jellyfin stopped or about to be restarted (the plugins read their files at start).
#
#   configure.sh --config-dir /srv/data/jellyfin/config --jellyfin-user-id GUID --floppy-url https://track.example.org --token-file FILE
set -euo pipefail

config=""; uid=""; url=""; tokfile=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config-dir) config="$2"; shift 2 ;;
    --jellyfin-user-id) uid="$2"; shift 2 ;;
    --floppy-url) url="${2%/}"; shift 2 ;;
    --token-file) tokfile="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
[ -n "$config" ] && [ -n "$uid" ] && [ -n "$url" ] && [ -r "$tokfile" ] || { echo "needs --config-dir, --jellyfin-user-id, --floppy-url, --token-file" >&2; exit 2; }
[[ "$uid" =~ ^[0-9A-Fa-f-]{36}$ ]] || { echo "the user id must be a GUID" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"
dir="$config/plugins/configurations"
[ -d "$dir" ] || { echo "$dir does not exist: start Jellyfin once with the plugins installed" >&2; exit 1; }
token="$(tr -d '\n\r ' < "$tokfile")"
[ -n "$token" ] || { echo "the token file is empty" >&2; exit 1; }
guid="$(echo "$uid" | tr 'A-F' 'a-f')"

# never overwrite settings somebody made by hand: only the pristine default or our own earlier output
# (the plugin's file names only the one option used here: what a file leaves out keeps the plugin's default)
for f in Jellyfin.Plugin.Webhook.xml Jellyfin.Plugin.ListenBrainz.xml; do
  if [ -e "$dir/$f" ] && ! grep -q 'floppy-managed' "$dir/$f" && ! grep -q -E '<GenericOptions />|<UserConfigs />' "$dir/$f"; then
    echo "$dir/$f has settings of its own: not touching it" >&2; exit 1
  fi
done

template_b64="$(base64 -w0 < "$here/webhook-template.hbs")"
token_b64="$(printf '%s' "$token" | base64 -w0)"

umask 077
cat > "$dir/Jellyfin.Plugin.Webhook.xml.new" <<XML
<?xml version="1.0" encoding="utf-8"?>
<!-- floppy-managed: written by nixos/floppy/jellyfin-link/configure.sh -->
<PluginConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <GenericOptions>
    <GenericOption>
      <NotificationTypes>
        <NotificationType>PlaybackStart</NotificationType>
        <NotificationType>PlaybackStop</NotificationType>
        <NotificationType>UserDataSaved</NotificationType>
      </NotificationTypes>
      <WebhookName>Floppy</WebhookName>
      <WebhookUri>${url}/webhook/jellyfin/${token}</WebhookUri>
      <EnableMovies>true</EnableMovies>
      <EnableEpisodes>true</EnableEpisodes>
      <EnableSeries>false</EnableSeries>
      <EnableSeasons>false</EnableSeasons>
      <EnableAlbums>false</EnableAlbums>
      <EnableSongs>false</EnableSongs>
      <EnableVideos>false</EnableVideos>
      <SendAllProperties>false</SendAllProperties>
      <TrimWhitespace>false</TrimWhitespace>
      <SkipEmptyMessageBody>false</SkipEmptyMessageBody>
      <EnableWebhook>true</EnableWebhook>
      <Template>${template_b64}</Template>
      <UserFilter>
        <guid>${guid}</guid>
      </UserFilter>
      <Headers>
        <GenericOptionValue>
          <Key>Content-Type</Key>
          <Value>application/json</Value>
        </GenericOptionValue>
      </Headers>
      <Fields />
    </GenericOption>
  </GenericOptions>
</PluginConfiguration>
XML

cat > "$dir/Jellyfin.Plugin.ListenBrainz.xml.new" <<XML
<?xml version="1.0" encoding="utf-8"?>
<!-- floppy-managed: written by nixos/floppy/jellyfin-link/configure.sh -->
<PluginConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <ListenBrainzApiUrl>${url}/apis/listenbrainz</ListenBrainzApiUrl>
  <MusicBrainzApiUrl>https://musicbrainz.org</MusicBrainzApiUrl>
  <MbidDelimiters>;,/</MbidDelimiters>
  <IsMusicBrainzEnabled>true</IsMusicBrainzEnabled>
  <IsAlternativeModeEnabled>false</IsAlternativeModeEnabled>
  <IsImmediateFavoriteSyncEnabled>false</IsImmediateFavoriteSyncEnabled>
  <UserConfigs>
    <UserConfig>
      <JellyfinUserId>${guid}</JellyfinUserId>
      <ApiToken>${token_b64}</ApiToken>
      <IsListenSubmitEnabled>true</IsListenSubmitEnabled>
      <IsFavoritesSyncEnabled>false</IsFavoritesSyncEnabled>
      <IsPlaylistsSyncEnabled>false</IsPlaylistsSyncEnabled>
      <IsGeneratedPlaylistsSyncEnabled>false</IsGeneratedPlaylistsSyncEnabled>
      <UserName>floppy</UserName>
      <IsBackupEnabled>false</IsBackupEnabled>
      <IsStrictModeEnabled>false</IsStrictModeEnabled>
    </UserConfig>
  </UserConfigs>
  <LibraryConfigs />
  <BackupPath />
  <IsAllPlaylistsSyncEnabled>false</IsAllPlaylistsSyncEnabled>
</PluginConfiguration>
XML

# the owner of the plugin files (the container runs as root on the server; a lab copy keeps the caller's): the same as the folder's
chown --reference="$dir" "$dir"/Jellyfin.Plugin.Webhook.xml.new "$dir"/Jellyfin.Plugin.ListenBrainz.xml.new 2>/dev/null || true
chmod 600 "$dir"/Jellyfin.Plugin.Webhook.xml.new "$dir"/Jellyfin.Plugin.ListenBrainz.xml.new
mv "$dir/Jellyfin.Plugin.Webhook.xml.new" "$dir/Jellyfin.Plugin.Webhook.xml"
mv "$dir/Jellyfin.Plugin.ListenBrainz.xml.new" "$dir/Jellyfin.Plugin.ListenBrainz.xml"
echo "configured for Jellyfin user $guid (token not shown); restart Jellyfin for the plugins to read it"
