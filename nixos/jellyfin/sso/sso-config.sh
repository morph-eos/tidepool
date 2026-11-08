#!/usr/bin/env bash
# Point Jellyfin's single sign-on plugin (SSO Authentication) at the identity provider, in the plugin's own settings file (SSO-Auth.xml).
#
#   sso-config.sh --config-dir DIR --provider NAME --endpoint URL --client-id ID --secret-file FILE [--check] [--adopt]
#
#   --config-dir   Jellyfin's plugin settings directory (…/config/plugins/configurations)
#   --provider     the name the login page uses: the button goes to /sso/OID/start/NAME, the identity provider redirects back to /sso/OID/redirect/NAME
#   --endpoint     the identity provider's address (https://cloud.example.org: Nextcloud's oidc app, whose discovery document is under it)
#   --client-id    the client's id as the identity provider knows it; --secret-file: a file that holds its secret (the secret is never printed, and never on a command line)
#   --check        say what would be done, change nothing (exit 0: already as declared, 10: something would change, 3: it differs and would not be touched, 4: the file is not valid XML)
#   --adopt        a provider that already exists with other values (by hand, or from before) is updated: its endpoint, client id, secret and Enabled flag only; everything else in the file (the links between the identity
#                  provider's users and Jellyfin's, the roles, the scopes) stays as it is. Without it such a file is left alone and the differences are named (never the values of the id or the secret).
#
# A file that is not there is written, with the settings this repository's lab proved (authorization off, every folder, scopes openid profile email groups, https). Jellyfin reads the file when it starts.
set -euo pipefail
shopt -u patsub_replacement 2>/dev/null || true   # bash 5.2 reads an & in a replacement as the matched text
usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
dir='' provider='' endpoint='' cid='' secretfile='' check=0 adopt=0
while [ $# -gt 0 ]; do
  case $1 in
    --config-dir) dir=${2:?}; shift 2 ;; --provider) provider=${2:?}; shift 2 ;; --endpoint) endpoint=${2:?}; shift 2 ;;
    --client-id) cid=${2:?}; shift 2 ;; --secret-file) secretfile=${2:?}; shift 2 ;;
    --check) check=1; shift ;; --adopt) adopt=1; shift ;; *) usage ;;
  esac
done
[ -n "$dir" ] && [ -n "$provider" ] && [ -n "$endpoint" ] && [ -n "$cid" ] && [ -n "$secretfile" ] || usage
for tool in xmlstarlet perl; do command -v "$tool" >/dev/null || { echo "$tool is needed" >&2; exit 2; }; done
[ -r "$secretfile" ] || { echo "cannot read the secret file" >&2; exit 2; }
[[ $provider =~ ^[A-Za-z0-9_-]+$ ]] || { echo "the provider name is letters, digits, - and _" >&2; exit 2; }
secret=$(<"$secretfile"); secret=${secret%$'\n'}
[ -n "$secret" ] || { echo "the secret file is empty" >&2; exit 2; }
f="$dir/SSO-Auth.xml"
esc() { local s=$1; s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; printf '%s' "$s"; }
item() {   # the settings of one provider; the values are put in by bash, so the secret is never in a process's arguments
  cat <<XML
    <item>
      <key>
        <string>$(esc "$provider")</string>
      </key>
      <value>
        <PluginConfiguration>
          <OidEndpoint>$(esc "$endpoint")</OidEndpoint>
          <OidClientId>$(esc "$cid")</OidClientId>
          <OidSecret>$(esc "$secret")</OidSecret>
          <Enabled>true</Enabled>
          <EnableAuthorization>false</EnableAuthorization>
          <EnableAllFolders>true</EnableAllFolders>
          <EnableContentDownloading xsi:nil="true" />
          <ApplyContentDownloadPermissionOnEveryLogin>false</ApplyContentDownloadPermissionOnEveryLogin>
          <EnabledFolders />
          <AdminRoles />
          <PreserveAdminPermissions>false</PreserveAdminPermissions>
          <Roles />
          <EnableFolderRoles>false</EnableFolderRoles>
          <EnableLiveTvRoles>false</EnableLiveTvRoles>
          <EnableLiveTv>false</EnableLiveTv>
          <EnableLiveTvManagement>false</EnableLiveTvManagement>
          <LiveTvRoles />
          <LiveTvManagementRoles />
          <FolderRoleMappings />
          <RoleClaim>groups</RoleClaim>
          <OidScopes>
            <string>openid</string>
            <string>profile</string>
            <string>email</string>
            <string>groups</string>
          </OidScopes>
          <OverrideDefaultScopes>false</OverrideDefaultScopes>
          <DefaultProvider />
          <SchemeOverride>https</SchemeOverride>
          <PortOverride xsi:nil="true" />
          <NewPath>true</NewPath>
          <CanonicalLinks />
          <DefaultUsernameClaim>preferred_username</DefaultUsernameClaim>
          <DisableHttps>false</DisableHttps>
          <DisablePushedAuthorization>true</DisablePushedAuthorization>
          <DoNotValidateEndpoints>false</DoNotValidateEndpoints>
          <DoNotValidateIssuerName>false</DoNotValidateIssuerName>
          <DoNotLoadProfile>false</DoNotLoadProfile>
        </PluginConfiguration>
      </value>
    </item>
XML
}
head='<?xml version="1.0" encoding="utf-8"?>
<PluginConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <SamlConfigs />
  <OidConfigs>'
tail='  </OidConfigs>
</PluginConfiguration>'

if [ ! -e "$f" ]; then
  if [ $check = 1 ]; then echo "SSO-Auth.xml is not there: it would be written, with the provider '$provider'"; exit 10; fi
  mkdir -p "$dir"; umask 077
  printf '%s\n%s\n%s\n' "$head" "$(item)" "$tail" > "$f"
  echo "SSO-Auth.xml written, with the provider '$provider'"; exit 0
fi

x() { xmlstarlet sel -T -t -v "$1" "$f" 2>/dev/null || true; }
base="/PluginConfiguration/OidConfigs/item[key/string='$provider']/value/PluginConfiguration"
n=$(xmlstarlet sel -T -t -v "count(/PluginConfiguration/OidConfigs/item[key/string='$provider'])" "$f" 2>/dev/null) || { echo "SSO-Auth.xml cannot be read as XML: left alone" >&2; exit 4; }
if [ "$n" = 0 ]; then
  if [ $check = 1 ]; then echo "SSO-Auth.xml has no provider '$provider': it would be added (the others stay)"; exit 10; fi
  new=$(item) perl -0pi -e 'my $n = $ENV{new}; if (s{<OidConfigs\s*/>}{<OidConfigs>\n$n\n  </OidConfigs>}) {} else { s{</OidConfigs>}{$n\n  </OidConfigs>} }' "$f"
  echo "the provider '$provider' added to SSO-Auth.xml"; exit 0
fi
diff=()
[ "$(x "$base/OidEndpoint")" = "$endpoint" ] || diff+=(OidEndpoint)
[ "$(x "$base/OidClientId")" = "$cid" ] || diff+=(OidClientId)
[ "$(x "$base/OidSecret")" = "$secret" ] || diff+=(OidSecret)
[ "$(x "$base/Enabled")" = "true" ] || diff+=(Enabled)
if [ ${#diff[@]} -eq 0 ]; then echo "the provider '$provider' is already as declared: nothing to do"; exit 0; fi
if [ $adopt = 0 ]; then
  echo "the provider '$provider' in SSO-Auth.xml differs in: ${diff[*]}; left alone (--adopt updates these four fields and nothing else)"
  exit 3
fi
if [ $check = 1 ]; then echo "the provider '$provider' would be updated in: ${diff[*]}"; exit 10; fi
# the four fields of this provider's block, in place: the values go in through the environment (a command line is visible to every local user)
E=$(esc "$endpoint") C=$(esc "$cid") S=$(esc "$secret") P=$provider perl -0pi -e '
  my $p = quotemeta($ENV{P});
  my $b = qr{(<key>\s*<string>$p</string>\s*</key>\s*<value>\s*<PluginConfiguration>.*?)}s;
  s{$b<OidEndpoint>.*?</OidEndpoint>}{$1<OidEndpoint>$ENV{E}</OidEndpoint>}s;
  s{$b<OidClientId>.*?</OidClientId>}{$1<OidClientId>$ENV{C}</OidClientId>}s;
  s{$b<OidSecret>.*?</OidSecret>}{$1<OidSecret>$ENV{S}</OidSecret>}s;
  s{$b<Enabled>.*?</Enabled>}{$1<Enabled>true</Enabled>}s;
' "$f"
echo "the provider '$provider' updated in SSO-Auth.xml: ${diff[*]}"
