#!/usr/bin/env bash
# Creates secrets.yaml, once: every secret that can be made here is generated; every secret that comes from somebody else (Brevo, Healthchecks, GitHub, the Wi-Fi, acme-dns) is
# a line "REPLACE-..." that tools/check.sh reports until it is real. Needs: sops, age (the key in ~/.config/tidepool/age.key), python3 with bcrypt, ssh-keygen, openssl.
# Usage: tools/secrets-init.sh        (refuses to overwrite an existing secrets.yaml)
set -euo pipefail
cd "$(dirname "$0")/.."
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/tidepool/age.key}"
SOPS="${SOPS:-sops}"
[ -e secrets.yaml ] && { echo "secrets.yaml exists: edit it with '$SOPS secrets.yaml'" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ssh-keygen -q -t ed25519 -N '' -C tidepool-deploy -f "$tmp/deploy"
openssl genpkey -algorithm X25519 -outform DER -out "$tmp/wg.der" 2>/dev/null
domain=$(sed -n 's/.*domain = "\([^"]*\)".*/\1/p' host.nix | head -1)
python3 - "$tmp" "$domain" <<'PY'
import base64, json, secrets, subprocess, sys, bcrypt
tmp = sys.argv[1]
rnd = lambda n=32: secrets.token_urlsafe(n)
der = open(f"{tmp}/wg.der", "rb").read()
priv = base64.b64encode(der[-32:]).decode()
pub = subprocess.run(["wg", "pubkey"], input=priv, capture_output=True, text=True, check=True).stdout.strip()
open("vpn-server.pub", "w").write(pub + "\n")
open("deploy.pub", "w").write(open(f"{tmp}/deploy.pub").read())
phone, bridge = rnd(18), rnd(18)
h = lambda p: bcrypt.hashpw(p.encode(), bcrypt.gensalt(10, prefix=b"2a")).decode()
def block(s): return "|\n" + "".join("  " + l + "\n" for l in s.rstrip("\n").split("\n"))
domain = sys.argv[2]
reg = lambda: {"username": "REPLACE-acme-dns-username", "password": "REPLACE-acme-dns-password", "fulldomain": "REPLACE-registration.auth.acme-dns.io", "subdomain": "REPLACE-registration", "allowfrom": []}
acme = {domain: reg(), "compute." + domain: reg()}   # the second one only if tidepool.compute.names.enable is used
out = {
    "borg-passphrase": rnd(), "pgbackrest-cipher": rnd(), "nextcloud-admin-pass": rnd(24), "proton-keyring-password": rnd(36),
    "wg-private-key": priv,
    "ntfy-env": f"NTFY_AUTH_USERS=phone:{h(phone)}:user,bridge:{h(bridge)}:user\nNTFY_AUTH_ACCESS=phone:alerts:read-only,bridge:alerts:write-only",
    "ntfy-bridge-env": f"ntfy:\n  auth:\n    basic:\n      username: bridge\n      password: {bridge}",
    "ntfy-phone-password": phone,   # typed once into the ntfy app on the phone (not read by the machine)
    "deploy-key": open(f"{tmp}/deploy").read(),
    "vaultwarden-env": "# ADMIN_TOKEN is not set: the admin panel is off. Mail for invitations is optional:\n# SMTP_HOST=smtp-relay.brevo.com\n# SMTP_PORT=587\n# SMTP_SECURITY=starttls\n# SMTP_USERNAME=\n# SMTP_PASSWORD=\n# SMTP_FROM=\n",
    "acme-dns-credentials": json.dumps(acme, indent=2),
    # from somebody else: tools/check.sh reports each until it is real
    "smtp-password": "REPLACE-brevo-smtp-key", "heartbeat-url": "REPLACE-healthchecks-ping-url", "alertmanager-env": "HEALTHCHECKS_MAIL=REPLACE-address-of-the-second-healthchecks-check",
    "renovate-token": "REPLACE-fine-grained-token-of-the-machine-user", "wifi-psk": "psk_home=REPLACE-64-hex-digits-from-wpa_passphrase",
    # from the application you move or set up: the WebDAV login (user:{PLAIN}password), Syncthing's cert and key if the device keeps its identity
    "webdav-htpasswd": "REPLACE-user:{PLAIN}password",
}
with open(f"{tmp}/plain.yaml", "w") as f:
    for k, v in out.items():
        f.write(f"{k}: " + (block(v) if "\n" in v else json.dumps(v)) + "\n")
PY
$SOPS --filename-override secrets.yaml -e --input-type yaml --output-type yaml "$tmp/plain.yaml" > secrets.yaml
echo "secrets.yaml written. Public halves: vpn-server.pub (for the VPN clients), deploy.pub (add it to this repository on GitHub as a read-only deploy key)."
