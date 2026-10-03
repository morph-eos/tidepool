{
  description = "tidepool: a private, re-engineered home server (host layer, services, backups, edge, VMs, observability)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    sops-nix = { url = "github:Mic92/sops-nix"; inputs.nixpkgs.follows = "nixpkgs"; };
    disko = { url = "github:nix-community/disko"; inputs.nixpkgs.follows = "nixpkgs"; };
  };

  outputs = { self, nixpkgs, sops-nix, disko, ... }:
    let
      mk = hostModule: nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ sops-nix.nixosModules.sops disko.nixosModules.disko ./modules hostModule ];
      };
    in
    {
      # for a private repository that imports this one: `tidepool.lib.mkHost ./host.nix` builds a host from these modules with the private values in host.nix (ADR 0016)
      lib.mkHost = mk;
      nixosConfigurations = {
        # the lab host: the same modules as the real one, with small stand-ins for what the lab cannot have (a test CA, a mail sink, no GPU)
        lab = mk ./hosts/lab;
        # the real host: the values that are private (domain, disks by serial, VPN peers) come from the private repository; this repository holds an example
        tidepool = mk ./hosts/tidepool;
      };
      # `nix flake check`: both hosts must build, on every change. The heavy proof (rebuild from blank and the restore) is lab/restore-drill.sh.
      checks.x86_64-linux = {
        lab = self.nixosConfigurations.lab.config.system.build.toplevel;
        tidepool = self.nixosConfigurations.tidepool.config.system.build.toplevel;
      };
    };
}
