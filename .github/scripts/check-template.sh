#!/usr/bin/env bash
# The template of the private repository works: its tools make a secrets file, say what is left, and add a VPN device. Run by the CI (`nix flake check`, check `template`) with sops, age,
# wireguard-tools, openssl, openssh, jq and a Python with bcrypt on the PATH.
# Usage: check-template.sh <the repository's private-repo-template directory>
set -euo pipefail
src="${1:?usage: check-template.sh <private-repo-template>}"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cp -r "$src/." "$work/"; chmod -R u+w "$work"; cd "$work"
export HOME="$work" SOPS_AGE_KEY_FILE="$work/age.key"
age-keygen -o "$SOPS_AGE_KEY_FILE" 2>/dev/null
printf 'creation_rules:\n  - path_regex: secrets\\.yaml$\n    key_groups:\n      - age:\n          - %s\n' "$(grep 'public key' "$SOPS_AGE_KEY_FILE" | sed 's/.*: //')" > .sops.yaml
fail() { echo "FAIL: $*" >&2; exit 1; }
bash tools/secrets-init.sh > /dev/null
[ -s vpn-server.pub ] && [ "$(wc -c < vpn-server.pub)" -eq 45 ] || fail "vpn-server.pub is not a WireGuard key"
[ -s deploy.pub ] || fail "no deploy.pub"
plain=$(sops -d secrets.yaml)
for k in borg-passphrase pgbackrest-cipher nextcloud-admin-pass immich-oauth-secret proton-keyring-password wg-private-key ntfy-env ntfy-bridge-env deploy-key acme-dns-credentials smtp-password heartbeat-url alertmanager-env renovate-token wifi-psk; do
  printf '%s\n' "$plain" | grep -q "^$k:" || fail "secrets.yaml has no $k"
done
n=$(sops -d --extract '["immich-oauth-secret"]' secrets.yaml | tr -d '\n' | wc -c); [ "$n" -ge 32 ] && [ "$n" -le 64 ] || fail "immich-oauth-secret is $n characters (Nextcloud takes 32 to 64)"
sops -d --extract '["acme-dns-credentials"]' secrets.yaml | jq -e 'length >= 2' > /dev/null || fail "acme-dns-credentials is not a JSON object with an entry for the domain and one for compute"
# what is left is said, and only the things somebody else issues
out=$(bash tools/check.sh || true)
printf '%s\n' "$out" | grep -q "to do" || fail "check.sh does not say what is left: $out"
for k in smtp-password heartbeat-url renovate-token wifi-psk; do printf '%s\n' "$out" | grep -q "$k" || fail "check.sh does not list $k"; done
printf '%s\n' "$out" | grep -q "borg-passphrase" && fail "check.sh lists a secret that was generated"
# a VPN device
bash tools/add-peer.sh phone 2 > peer.txt
grep -q '^PrivateKey = ' peer.txt && grep -q "$(cat vpn-server.pub)" peer.txt || fail "add-peer.sh did not print a client configuration"
grep -q '10.100.0.2/32' vpn-peers.nix || fail "add-peer.sh did not write vpn-peers.nix"
! bash tools/add-peer.sh other 2 > /dev/null 2>&1 || fail "add-peer.sh accepted an address that is taken"
echo "the template's tools work"
