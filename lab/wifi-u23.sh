#!/usr/bin/env bash
# =============================================================================
# lab/wifi-u23.sh — the server on WiFi (modules/wifi.nix): a virtual radio pair (mac80211_hwsim), a real hostapd access point with DHCP in a network namespace, and the lab host
# connecting to it with wpa_supplicant, the key (derived from the name and the passphrase) coming from the sops secret `wifi-psk`; the NAS share reachable over that interface and nowhere else.
# Runs INSIDE the lab host as root; /home/lab/nixos is the flake.
# =============================================================================
set -uo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH
export NIX_CONFIG='experimental-features = nix-command flakes
download-attempts = 60'
say() { echo "$(date +%H:%M:%S) $*"; }
P=path:/home/lab/nixos#nixosConfigurations.lab.pkgs
for t in iw hostapd dnsmasq samba; do eval "$(echo $t | tr a-z A-Z)=$(nix build --no-link --print-out-paths "$P.$t^out" | head -n 1)"; done
say "== the access point: a virtual radio moved into a namespace, hostapd (WPA2), dnsmasq for DHCP"
rmmod mac80211_hwsim 2>/dev/null; pkill hostapd 2>/dev/null; pkill dnsmasq 2>/dev/null; sleep 1
modprobe mac80211_hwsim radios=2
ip netns del ap 2>/dev/null; ip netns add ap
$IW/bin/iw phy phy$(cat /sys/class/net/wlan0/phy80211/index) set netns name ap   # the radio behind wlan0 (its number grows with every load of the module)
ip netns exec ap ip addr add 192.168.77.1/24 dev wlan0; ip netns exec ap ip link set wlan0 up
cat > /tmp/hostapd.conf <<'N'
interface=wlan0
driver=nl80211
ssid=Home&Life Test
hw_mode=g
channel=1
wpa=2
wpa_key_mgmt=WPA-PSK
wpa_passphrase=labwifipass
rsn_pairwise=CCMP
N
startap() {
  pkill hostapd 2>/dev/null; ip netns exec ap $HOSTAPD/bin/hostapd -B -P /tmp/hostapd.pid /tmp/hostapd.conf >/dev/null 2>&1
  ip netns exec ap $DNSMASQ/bin/dnsmasq --interface=wlan0 --bind-interfaces --dhcp-range=192.168.77.10,192.168.77.50,12h --pid-file=/tmp/dnsmasq-ap.pid --dhcp-leasefile=/tmp/dnsmasq.leases
}
say "the radios are ready; the access point is NOT started yet (it comes up after the activation, as a router does after a boot)"
say "== the lab host with tidepool.wifi on wlan1 (the NAS on that interface)"
cat > /home/lab/nixos/hosts/lab/wifi-test.nix <<'N'
{ lib, ... }: { tidepool.wifi = { enable = true; interface = "wlan1"; ssid = "Home&Life Test"; }; tidepool.lanInterface = lib.mkForce "wlan1"; }
N
sed -i 's|  imports = \[|  imports = [ ./wifi-test.nix|' /home/lab/nixos/hosts/lab/default.nix
s=$(date +%s); nixos-rebuild test --flake path:/home/lab/nixos#lab 2>&1 | grep -v "^evaluation warning" | tail -n 3 | cut -c1-170; say "switch: $(( $(date +%s) - s )) s; the Samba units before any address: smbd $(systemctl is-active samba-smbd), nmbd $(systemctl is-active samba-nmbd) (they wait or retry)"
startap; say "the access point is up: $(ip netns exec ap $IW/bin/iw dev wlan0 info | grep -E 'ssid' | tr -s ' \t' ' ')"
for i in $(seq 1 40); do ip -4 addr show wlan1 | grep -q "inet 192.168.77" && break; sleep 2; done
sleep 25; say "after the address came: smbd $(systemctl is-active samba-smbd), nmbd $(systemctl is-active samba-nmbd)"
say "wpa_supplicant: $(systemctl is-active wpa_supplicant-wlan1); state: $(wpa_cli -i wlan1 status 2>&1 | grep -E '^(ssid|wpa_state)=' | tr '\n' ' ')"
say "address from DHCP: $(ip -4 -br addr show wlan1 | tr -s ' ')"
say "power saving on the interface: $($IW/bin/iw dev wlan1 get power_save 2>&1 | tr -s ' ')   (the udev rule runs when the interface appears; the lab's virtual radio may not report it)"
say "the passphrase is not in the Nix store: $(grep -rl labwifipass /nix/store/*wpa_supplicant* /etc/wpa_supplicant* 2>/dev/null | wc -l) files hold it; the unit's config uses: $(grep -h 'psk' /etc/wpa_supplicant/*.conf /run/wpa_supplicant/*.conf 2>/dev/null | head -2 | tr '\n' ' ' | cut -c1-80)"
echo "== the NAS over the WiFi interface"
printf 'labnaspw\nlabnaspw\n' | smbpasswd -a -s nas >/dev/null 2>&1
IPW=$(ip -4 -br addr show wlan1 | awk '{print $3}' | cut -d/ -f1)
say "from the access point's side (another device on the WiFi): ping $(ip netns exec ap ping -c 2 -W 2 $IPW 2>&1 | grep -c '2 received') ok; SMB share list: $(ip netns exec ap $SAMBA/bin/smbclient -L //$IPW -U nas%labnaspw 2>&1 | grep -E 'Disk' | tr -s ' ' | cut -d' ' -f2 | tr '\n' ' ')"
say "firewall: 445 open only on $(nft list ruleset | grep -B3 'dport 445' | grep -oE 'iifname "[a-z0-9]+"' | sort -u | tr '\n' ' ')"
rm -f /home/lab/nixos/hosts/lab/wifi-test.nix; sed -i 's|  imports = \[ ./wifi-test.nix|  imports = [|' /home/lab/nixos/hosts/lab/default.nix
say done
