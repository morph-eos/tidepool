# The private repository (template)

Copy this directory to a **new private repository**. It holds the values of one machine and imports the public `tidepool` flake. See `docs/decisions/0018-deploys-by-the-server.md`.

1. Replace `OWNER`, `PRIVATE-REPO`, every `REPLACE-...` and the example values in `host.nix`.
2. Create the machine's age key; write `.sops.yaml`; create `secrets.yaml` with the secrets of the public example file (`nixos/secrets/example.yaml` lists the names) **and** `deploy-key`.
3. Generate the deploy key **on the workstation**: `ssh-keygen -t ed25519 -N '' -C tidepool-deploy -f deploy`; put the private half in `secrets.yaml` as `deploy-key`; add `deploy.pub` to this repository as a **read-only deploy key** (Settings > Deploy keys; leave "Allow write access" off); delete both files.
4. `nix flake lock`, commit, push. Install the machine with `nixos-install --flake .#tidepool` from a clone.
5. In Settings > Actions > General turn on "Allow GitHub Actions to create and approve pull requests" for `bump-public.yml`.
6. **Renovate on the server:** create a **machine user** (a second free GitHub account), invite it to the public repository with the **Write** role (not Admin), create a **fine-grained token** for it (contents and pull requests: read and write, on the public repository only), put it in `secrets.yaml` as `renovate-token`. It expires: when it does, the `renovate` unit fails and the `UnitFailed` mail says so.
7. **WiFi** (until the cable is connected): compute the key with `wpa_passphrase 'YOUR SSID' 'your passphrase'` (it prints `psk=<64 hex digits>`; keep the hex, not the passphrase) and put one line in `secrets.yaml` as `wifi-psk`: `psk_home=<the 64 hex digits>`. The router must give the machine the same address every time (a reservation by the card's address); the machine's WiFi address is the card's own, not a random one.
