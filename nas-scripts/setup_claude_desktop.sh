#!/usr/bin/env bash
# =============================================================================
# Setup Claude Desktop + browser environment (privacy-focused).
#  - Claude Desktop (community build aaddrick) + MCP (filesystem /mnt, Playwright)
#    + autostart at power-on (GNOME autologin).
#  - Chrome (Claude's browser): install + ONE-TIME warm-up + managed
#    anti-telemetry/tracking policies.
#  - Firefox (user browser): default + anti-telemetry policies/prefs (strict ETP).
# Idempotent. Run AS REDACTED_HOSTNAME (uses sudo internally for apt and /etc).
# Logins (manual, at the end of setup): Claude Desktop + Claude in Chrome extension.
# =============================================================================
set -uo pipefail
TARGET_USER=REDACTED_HOSTNAME
if [ "$(id -un)" != "$TARGET_USER" ]; then echo "Esegui come $TARGET_USER (NON root): sudo -u $TARGET_USER $0"; exit 1; fi
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_DATA_DIRS="${XDG_DATA_DIRS:-/usr/local/share/:/usr/share/:/var/lib/snapd/desktop}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
CFG_DIR="$HOME/.config/Claude"; CFG="$CFG_DIR/claude_desktop_config.json"
AUTOSTART="$HOME/.config/autostart/claude-desktop.desktop"
CHROME_MARKER="$HOME/.config/.chrome-virginized"

echo "== Claude Desktop + ambiente browser =="

# --- A) Claude Desktop: repo + install --------------------------------------
KEY=/usr/share/keyrings/claude-desktop.gpg
if [ ! -s "$KEY" ]; then curl -fsSL https://pkg.claude-desktop-debian.dev/KEY.gpg | sudo gpg --dearmor -o "$KEY"; fi
LST=/etc/apt/sources.list.d/claude-desktop.list
grep -qsF 'pkg.claude-desktop-debian.dev' "$LST" 2>/dev/null || \
  echo 'deb [signed-by=/usr/share/keyrings/claude-desktop.gpg arch=amd64,arm64] https://pkg.claude-desktop-debian.dev stable main' | sudo tee "$LST" >/dev/null
if ! dpkg -s claude-desktop >/dev/null 2>&1; then
  sudo apt-get update -qq; sudo apt-get install -y claude-desktop && echo "[A] claude-desktop installato"
else
  sudo apt-get install -y --only-upgrade claude-desktop >/dev/null 2>&1 || true
  echo "[A] claude-desktop presente (v$(dpkg -s claude-desktop 2>/dev/null | awk '/^Version/{print $2}'))"
fi

# --- B) Claude Desktop MCP config (non-destructive merge) -------------------
mkdir -p "$CFG_DIR"; [ -f "$CFG" ] || echo '{}' > "$CFG"
python3 - "$CFG" <<'PYEOF'
import json,sys
p=sys.argv[1]
try: c=json.load(open(p))
except Exception: c={}
c.setdefault("mcpServers",{})
want={"REDACTED_BRAND_lc-fs":{"command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","/mnt"]},
      "playwright":{"command":"npx","args":["-y","@playwright/mcp@latest","--browser","chrome"]}}
ch=False
for k,v in want.items():
    if c["mcpServers"].get(k)!=v: c["mcpServers"][k]=v; ch=True
json.dump(c,open(p,"w"),indent=2)
print("[B] config MCP aggiornata" if ch else "[B] config MCP gia' a posto")
PYEOF

# --- C) Autostart -----------------------------------------------------------
mkdir -p "$(dirname "$AUTOSTART")"
DESK='[Desktop Entry]
Type=Application
Name=Claude
Exec=/usr/bin/claude-desktop
Icon=claude-desktop
X-GNOME-Autostart-enabled=true'
[ "$(cat "$AUTOSTART" 2>/dev/null)" = "$DESK" ] || { printf '%s\n' "$DESK" > "$AUTOSTART"; echo "[C] autostart impostato"; }

# --- D) Chrome: install (Google repo if absent) -----------------------------
if ! dpkg -s google-chrome-stable >/dev/null 2>&1; then
  curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
  echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main' | sudo tee /etc/apt/sources.list.d/google-chrome.list >/dev/null
  sudo apt-get update -qq; sudo apt-get install -y google-chrome-stable && echo "[D] Chrome installato"
else
  echo "[D] Chrome gia' installato"
fi

# --- E) Chrome: ONE-TIME warm-up (marker) -----------------------------------
if [ ! -f "$CHROME_MARKER" ]; then
  pkill -u "$TARGET_USER" -x chrome 2>/dev/null || true; sleep 1
  rm -rf "$HOME/.config/google-chrome" "$HOME/.cache/google-chrome" 2>/dev/null || true
  touch "$CHROME_MARKER"
  echo "[E] Chrome inverginato (profilo+cache azzerati)"
else
  echo "[E] Chrome gia' inverginato in precedenza (preservo login/estensione)"
fi

# --- F) Chrome: managed anti-tracking policies ------------------------------
sudo mkdir -p /etc/opt/chrome/policies/managed
sudo tee /etc/opt/chrome/policies/managed/00-REDACTED_BRAND_lc-privacy.json >/dev/null <<'JSON'
{
  "MetricsReportingEnabled": false,
  "UrlKeyedAnonymizedDataCollectionEnabled": false,
  "SafeBrowsingProtectionLevel": 0,
  "SafeBrowsingExtendedReportingEnabled": false,
  "SearchSuggestEnabled": false,
  "SpellCheckServiceEnabled": false,
  "PasswordManagerEnabled": false,
  "AutofillAddressEnabled": false,
  "AutofillCreditCardEnabled": false,
  "SyncDisabled": true,
  "BrowserSignin": 0,
  "PromotionalTabsEnabled": false,
  "FeedbackSurveysEnabled": false,
  "DefaultBrowserSettingEnabled": false,
  "BackgroundModeEnabled": false,
  "MetricsReportingEnabled": false,
  "ShoppingListEnabled": false,
  "MediaRecommendationsEnabled": false
}
JSON
echo "[F] Chrome: policy anti-tracking applicate"

# --- G) Firefox: default + privacy ------------------------------------------
FFD=firefox_firefox.desktop
xdg-settings set default-web-browser "$FFD" 2>/dev/null || true
xdg-mime default "$FFD" x-scheme-handler/http x-scheme-handler/https x-scheme-handler/about x-scheme-handler/unknown text/html 2>/dev/null || true
python3 - "$HOME/.config/mimeapps.list" "$FFD" <<'PYIN'
import configparser,sys,os
m,ff=sys.argv[1],sys.argv[2]; cp=configparser.ConfigParser(); cp.optionxform=str
os.path.exists(m) and cp.read(m)
s="Default Applications"; cp.has_section(s) or cp.add_section(s)
for k in ["x-scheme-handler/http","x-scheme-handler/https","text/html","x-scheme-handler/about","x-scheme-handler/unknown"]: cp.set(s,k,ff)
with open(m,"w") as f: cp.write(f,space_around_delimiters=False)
PYIN
sudo mkdir -p /etc/firefox/policies
sudo tee /etc/firefox/policies/policies.json >/dev/null <<'JSON'
{ "policies": {
  "DisableTelemetry": true, "DisableFirefoxStudies": true, "DisablePocket": true,
  "DisableDefaultBrowserAgent": true, "DontCheckDefaultBrowser": true,
  "EnableTrackingProtection": { "Value": true, "Locked": true, "Cryptomining": true, "Fingerprinting": true },
  "FirefoxHome": { "SponsoredTopSites": false, "SponsoredPocket": false, "Pocket": false },
  "UserMessaging": { "WhatsNew": false, "ExtensionRecommendations": false, "FeatureRecommendations": false, "SkipOnboarding": true },
  "OverrideFirstRunPage": "", "OverridePostUpdatePage": "" } }
JSON
FFP=$(ls -d "$HOME"/snap/firefox/common/.mozilla/firefox/*.default* 2>/dev/null | head -1)
if [ -n "$FFP" ]; then
cat > "$FFP/user.js" <<'USERJS'
// Privacy/anti-tracking tidepool
user_pref("toolkit.telemetry.enabled", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("toolkit.telemetry.archive.enabled", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("app.shield.optoutstudies.enabled", false);
user_pref("app.normandy.enabled", false);
user_pref("browser.discovery.enabled", false);
user_pref("browser.newtabpage.activity-stream.showSponsored", false);
user_pref("browser.newtabpage.activity-stream.showSponsoredTopSites", false);
user_pref("browser.urlbar.suggest.quicksuggest.sponsored", false);
user_pref("browser.urlbar.suggest.quicksuggest.nonsponsored", false);
user_pref("privacy.trackingprotection.enabled", true);
user_pref("privacy.donottrackheader.enabled", true);
user_pref("privacy.globalprivacycontrol.enabled", true);
user_pref("network.cookie.cookieBehavior", 5);
user_pref("geo.enabled", false);
user_pref("beacon.enabled", false);
user_pref("browser.contentblocking.category", "strict");
USERJS
echo "[G] Firefox: predefinito + privacy (policies + user.js)"
else
echo "[G] Firefox predefinito + policy (user.js: profilo non trovato, avvia Firefox una volta)"
fi

# --- H) Manual steps --------------------------------------------------------
echo ""
echo "PASSAGGI MANUALI (monitor collegato):"
echo "  1) Apri Claude Desktop e accedi con l'account Anthropic."
echo "  2) Apri Chrome, installa l'estensione 'Claude' dal Chrome Web Store e accedi."
echo "ESITO: setup Claude Desktop + browser completato"
