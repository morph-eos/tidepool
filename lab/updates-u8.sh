#!/usr/bin/env bash
# =============================================================================
# lab/updates-u8.sh — phase 8 (ADR 0016), U8: how the private values (domain, disks, VPN peers, secrets) reach the real host without being in the public repository.
#   A. the public flake as the only flake, the private values as an input replaced at build time (`--override-input`)
#   B. a private flake that IMPORTS the public one and calls its `lib.mkHost`
# Measured: that both build, that the nixpkgs revision deployed is the one the public repository's lock tested, and what a `nix flake update` of the private flake does to it.
# Runs INSIDE the lab host as root; /home/lab/nixos is the public flake (with lib.mkHost).
# =============================================================================
set -uo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH
export NIX_CONFIG='experimental-features = nix-command flakes
download-attempts = 60
stalled-download-timeout = 120'
say() { echo "$(date +%H:%M:%S) $*"; }
rev() { jq -r '.nodes.nixpkgs.locked.rev[0:8]' "$1"; }
rm -rf /root/pub /root/priv; cp -r /home/lab/nixos /root/pub
say "public flake locks nixpkgs at $(rev /root/pub/flake.lock) (its own tests ran against that)"
mkdir -p /root/priv; cd /root/priv
cat > host.nix <<'NIX'
# the private values (this file and secrets.yaml live in the private repository)
{ ... }:
{
  networking.hostName = "tidepool";
  tidepool = {
    domain = "home.example";
    secretsFile = ./secrets.yaml;
    admin = { name = "owner"; key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPRIVATEPRIVATEPRIVATEPRIVATEPRIVATE000000 owner"; };
    boot.mode = "uefi";
    disks = { system = "/dev/disk/by-id/nvme-PRIVATE-system"; tank = "/dev/disk/by-id/nvme-PRIVATE-tank"; backup16 = "/dev/disk/by-id/ata-PRIVATE16-part1"; big2tb = "/dev/disk/by-id/ata-PRIVATE2-part1"; };
    wireguard.peers = [ { name = "phone"; publicKey = "UsaBPzc5X1Dp790FiPrAGPf1sLaSfytknMGVTQLsKFM="; allowedIPs = [ "10.100.0.2/32" ]; } ];
  };
}
NIX
cp /root/pub/secrets/lab.yaml secrets.yaml
echo "== B. a private flake that imports the public one"
cat > flake.nix <<'NIX'
{
  inputs.tidepool.url = "path:/root/pub";
  outputs = { self, tidepool, ... }: {
    nixosConfigurations.tidepool = tidepool.lib.mkHost ./host.nix;
  };
}
NIX
nix flake lock 2>&1 | grep -E "Added|error" | head -n 3 | cut -c1-200
say "B builds (eval): $(nix eval --raw path:.#nixosConfigurations.tidepool.config.system.build.toplevel.drvPath 2>&1 | grep -v '^evaluation warning' | tail -n 1 | sed 's#/nix/store/[a-z0-9]*-##')"
say "B: the host's domain comes from the private file: $(nix eval --raw path:.#nixosConfigurations.tidepool.config.tidepool.domain 2>&1 | tail -n 1), disks: $(nix eval --raw path:.#nixosConfigurations.tidepool.config.tidepool.disks.system 2>&1 | tail -n 1)"
say "B: nixpkgs in the private lock: $(jq -r '[.nodes | to_entries[] | select(.key|startswith("nixpkgs")) | .value.locked.rev[0:8]] | unique | join(" ")' flake.lock) (public lock: $(rev /root/pub/flake.lock))"
say "B: input nodes in the private lock: $(jq -r '.nodes|keys|join(" ")' flake.lock)"
say "-- the public repository moves on: its lock is bumped to the latest nixpkgs (a commit in the public repository)"
(cd /root/pub && nix flake lock --update-input nixpkgs >/dev/null 2>&1; say "public lock now at $(rev flake.lock)")
say "-- in the private flake: nix flake update tidepool (only that input)"
nix flake update tidepool 2>&1 | grep -E "Updated|error" | head -n 4 | cut -c1-200
say "B after 'nix flake update tidepool': nixpkgs in the private lock: $(jq -r '[.nodes | to_entries[] | select(.key|startswith("nixpkgs")) | .value.locked.rev[0:8]] | unique | join(" ")' flake.lock)  (public lock: $(rev /root/pub/flake.lock))"
say "-- in the private flake: a bare nix flake update (all inputs)"
nix flake update 2>&1 | grep -E "Updated|error" | head -n 4 | cut -c1-200
say "B after a bare 'nix flake update': nixpkgs in the private lock: $(jq -r '[.nodes | to_entries[] | select(.key|startswith("nixpkgs")) | .value.locked.rev[0:8]] | unique | join(" ")' flake.lock)"
echo "== A. the public flake is the only flake; the private values are an INPUT with an example as its default, replaced at build time"
rm -rf /root/pubA /root/privA; cp -r /home/lab/nixos /root/pubA; cd /root/pubA
python3 - <<'PY'
p="/root/pubA/flake.nix"; s=open(p).read()
s=s.replace('nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";','nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";\n    private.url = "path:./vars";   # a small flake with the example values; the real one replaces it at build time')
s=s.replace("outputs = { self, nixpkgs, sops-nix, disko, ... }:","outputs = { self, nixpkgs, sops-nix, disko, private, ... }:")
s=s.replace("tidepool = mk ./hosts/tidepool;","tidepool = mk private.nixosModules.default;")
open(p,"w").write(s)
PY
# the example values become a self-contained flake (a flake cannot read files outside its own directory)
mkdir -p vars; cp secrets/lab.yaml vars/secrets.yaml; cp keys/admin.pub vars/admin.pub
cat > vars/default.nix <<'NIX'
{ ... }:
{
  networking.hostName = "tidepool";
  sops.validateSopsFiles = false;
  tidepool = {
    domain = "example.invalid"; secretsFile = ./secrets.yaml;
    admin = { name = "admin"; key = builtins.readFile ./admin.pub; };
    boot.mode = "uefi";
    disks = { system = "/dev/disk/by-id/EXAMPLE-system"; tank = "/dev/disk/by-id/EXAMPLE-tank"; backup16 = "/dev/disk/by-id/EXAMPLE-16tb-part1"; big2tb = "/dev/disk/by-id/EXAMPLE-2tb-part1"; };
  };
}
NIX
printf '{ outputs = { self }: { nixosModules.default = ./default.nix; }; }\n' > vars/flake.nix
rm -f flake.lock; cp /home/lab/nixos/flake.lock flake.lock
nix flake lock 2>&1 | grep -E "Added|error" | head -n 4 | cut -c1-200
say "A (CI, the default input): the domain is $(nix eval --raw path:.#nixosConfigurations.tidepool.config.tidepool.domain 2>&1 | tail -n 1)"
mkdir -p /root/privA; cp /root/priv/host.nix /root/privA/default.nix; cp /root/priv/secrets.yaml /root/privA/secrets.yaml
printf '{ outputs = { self }: { nixosModules.default = ./default.nix; }; }\n' > /root/privA/flake.nix
say "A (the owner's build, --override-input private path:/root/privA): the domain is $(nix eval --raw path:.#nixosConfigurations.tidepool.config.tidepool.domain --override-input private path:/root/privA 2>&1 | tail -n 1), disks: $(nix eval --raw path:.#nixosConfigurations.tidepool.config.tidepool.disks.system --override-input private path:/root/privA 2>&1 | tail -n 1)"
say "A: the real host's toplevel evaluates: $(nix eval --raw path:.#nixosConfigurations.tidepool.config.system.build.toplevel.drvPath --override-input private path:/root/privA 2>&1 | grep -v '^evaluation warning' | tail -n 1 | sed 's#/nix/store/[a-z0-9]*-##')"
say "A: nixpkgs deployed = nixpkgs in the public lock = $(rev flake.lock) (there is only one lock file, the one CI tested); nix flake lock did not touch the override: lock mentions private as $(jq -r '.nodes.private.locked.type // "?"' flake.lock)"
say done
