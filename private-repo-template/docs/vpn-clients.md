# The VPN clients

The server is `10.100.0.1` on WireGuard (UDP 51820, forwarded by the router to the machine; the endpoint is your dynamic-DNS name, set with ENDPOINT=... for add-peer.sh). Each device is one peer.

## Add a device
```
tools/add-peer.sh phone 2        # 10.100.0.2; prints the client's configuration ONCE
tools/add-peer.sh laptop 3
git add vpn-peers.nix && git commit -m "VPN: phone, laptop"      # the server takes it at the next deploy
```
The configuration routes `10.100.0.0/24` (the VPN) and `10.100.1.0/24` (the Incus instances) only; the rest of the traffic does not go through the server. On a phone, import it with the WireGuard app (a QR code of the block, or a file).

## Reach the machine
- SSH: `ssh -p 2222 <admin>@10.100.0.1` (only through the VPN).
- The VPN-only names: `https://sync.<domain>`, `https://metrics.<domain>`, `https://alerts.<domain>`, `https://compute.<domain>:8443`, and `https://admin.<domain>`, the page that lists them all (they resolve to 10.100.0.1). If the router drops answers that point to a private address (DNS rebind protection), add an exception for the domain.
- The Incus instances: `https://<instance>.compute.<domain>` (their port 80); and by SSH with a name, `ssh <user>@<instance>.incus`, once the device sends the `.incus` names to 10.100.0.1:
  - Linux with systemd-resolved: `resolvectl dns <wireguard interface> 10.100.0.1` and `resolvectl domain <wireguard interface> '~incus'`;
  - macOS: a file `/etc/resolver/incus` holding `nameserver 10.100.0.1`;
  - Android: the instance's address instead (`incus list`).

## Remove a device
Delete its line from `vpn-peers.nix` and deploy; a device that is lost should be removed at once.
