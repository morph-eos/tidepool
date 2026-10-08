# The private repository (template)

Copy this directory to a **new private repository**. It holds the values of one machine and imports the public `tidepool` flake. See `docs/decisions/0018-deploys-by-the-server.md`.

1. Replace `OWNER`, `PRIVATE-REPO`, every `REPLACE-...` and the example values in `host.nix`.
2. Create the machine's age key (`age-keygen -o ~/.config/tidepool/age.key`; **write it down in Proton Pass and on paper**, and keep it out of the repository) and write its public half into `.sops.yaml` (`creation_rules: - path_regex: secrets\.yaml$ ... age: [ <the public key> ]`). Then `tools/secrets-init.sh` makes `secrets.yaml`: it **generates** what can be generated (the Borg and pgBackRest passphrases, the Nextcloud admin password, the VPN key, the ntfy logins, the deploy key, the Proton keyring password) and leaves a `REPLACE-...` line for what somebody else issues (Brevo, Healthchecks, the Wi-Fi, GitHub, acme-dns). `tools/check.sh` lists what is left; `tools/check.sh --build` also evaluates the host.
3. Generate the deploy key **on the workstation**: `ssh-keygen -t ed25519 -N '' -C tidepool-deploy -f deploy`; put the private half in `secrets.yaml` as `deploy-key`; add `deploy.pub` to this repository as a **read-only deploy key** (Settings > Deploy keys; leave "Allow write access" off); delete both files.
4. `nix flake lock`, commit, push. Install the machine with `nixos-install --flake .#tidepool` from a clone.
5. In Settings > Actions > General turn on "Allow GitHub Actions to create and approve pull requests" for `bump-public.yml`.
6. **Renovate on the server:** create a **machine user** (a second free GitHub account), invite it to the public repository with the **Write** role (not Admin), create a **fine-grained token** for it (contents and pull requests: read and write, on the public repository only), put it in `secrets.yaml` as `renovate-token`. It expires: when it does, the `renovate` unit fails and the `UnitFailed` mail says so.
7. **WiFi** (until the cable is connected): compute the key with `wpa_passphrase 'YOUR SSID' 'your passphrase'` (it prints `psk=<64 hex digits>`; keep the hex, not the passphrase) and put one line in `secrets.yaml` as `wifi-psk`: `psk_home=<the 64 hex digits>`. The router must give the machine the same address every time (a reservation by the card's address); the machine's WiFi address is the card's own, not a random one.
8. **Certificates** (the DNS challenge is delegated to acme-dns, [ADR 0008](../docs/decisions/0008-edge.md)): for **each certificate name** (the domain, and `compute.<domain>` if you use `tidepool.compute.names.enable`) register once with the public instance, `curl -s -X POST https://auth.acme-dns.io/register` (it answers `username`, `password`, `fulldomain`, `subdomain`, `allowfrom`; **the password is shown only once**). At the DNS provider make a CNAME from `_acme-challenge` (and `_acme-challenge.compute`) to that answer's `fulldomain`. Put the answers in `secrets.yaml` as **`acme-dns-credentials`**, one JSON object keyed by the certificate's name:

   ```json
   {
     "example.org":         { "username": "...", "password": "...", "fulldomain": "...auth.acme-dns.io", "subdomain": "...", "allowfrom": [] },
     "compute.example.org": { "username": "...", "password": "...", "fulldomain": "...auth.acme-dns.io", "subdomain": "...", "allowfrom": [] }
   }
   ```

   The host reads it at `/run/secrets/acme-dns-credentials` (owner `acme`) and nothing else is needed. Check after the first deploy: `systemctl status acme-order-renew-<domain>` and `journalctl -u 'acme-*'`; a name with no entry fails with "no account".

## The tools
| | |
|---|---|
| `tools/secrets-init.sh` | makes `secrets.yaml` once (needs `sops`, `age`, `wg`, `openssl`, `ssh-keygen`, Python with `bcrypt`); writes `vpn-server.pub` and `deploy.pub` |
| `tools/check.sh [--build]` | the placeholders still in `host.nix` and `secrets.yaml`; with `--build` the whole host is evaluated; exit status = the number of problems |
| `tools/set-wifi.sh` | asks the Wi-Fi passphrase and writes the 64 hex digits for the network in `host.nix` |
| `tools/add-peer.sh NAME N` | a VPN device: its key pair, its line in `vpn-peers.nix`, and the client's configuration shown once ([docs/vpn-clients.md](docs/vpn-clients.md)) |

A move from an existing server adds its own script next to these (a private repository can have one that copies the old WebDAV login, Syncthing identity and application tokens into `secrets.yaml` without printing them).

## Adding your own modules (anything the public repository does not have)

Put them in this repository and import them from `host.nix`; **nothing of the public repository is replaced or edited**. `host.nix` is one more NixOS module, and the module system merges it with the public ones:

```nix
{ ... }: {
  imports = [ ./modules/my-service.nix ];   # your own module, your own options
}
```

- **Additive:** services, systemd units, nginx virtual hosts (`services.nginx.virtualHosts."name.${config.tidepool.domain}"`), users, packages and sops secrets (`sops.secrets.NAME.sopsFile = ./secrets.yaml;`) from your module simply join what the public host defines.
- **Lists and attribute sets merge:** to back up your service's data, add its path to the Borg job (`services.borgbackup.jobs.everything.paths = [ "/var/lib/my-service" ];`); the public paths stay.
- **A single value that both sides set** (two different strings for the same option) is a conflict the build reports; override the public one with `lib.mkForce` in `host.nix`.
- **To switch a public service off**, set its option in `host.nix` (for example `tidepool.services.jellyfin.enable = false;`).
- A public module is replaced by your own file only if you stop importing it, and that is never necessary: the options exist to avoid it.

`lab/experiments/private-modules/` and `lab/experiments/private-modules-u26.sh` are a throwaway example of this shape: the lab host plus a module of its own, built and run in a VM (six checks: the unit, its secret, its virtual host, its backup path, the public paths, the public services).

