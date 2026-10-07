{
  description = "tidepool: a private, re-engineered home server (host layer, services, backups, edge, VMs, observability)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    sops-nix = { url = "github:Mic92/sops-nix"; inputs.nixpkgs.follows = "nixpkgs"; };
    disko = { url = "github:nix-community/disko"; inputs.nixpkgs.follows = "nixpkgs"; };
    lanzaboote = { url = "github:nix-community/lanzaboote/v1.2.0"; inputs.nixpkgs.follows = "nixpkgs"; };   # signed boot images (Secure Boot with the owner's keys), ADR 0005
  };

  outputs = { self, nixpkgs, sops-nix, disko, lanzaboote, ... }:
    let
      mk = hostModule: nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ sops-nix.nixosModules.sops disko.nixosModules.disko lanzaboote.nixosModules.lanzaboote ./modules hostModule ];
      };
    in
    {
      # for a private repository that imports this one: `tidepool.lib.mkHost ./host.nix` builds a host from these modules with the private values in host.nix (ADR 0016)
      lib.mkHost = mk;
      nixosConfigurations = {
        # the lab host: the same modules as the real one, with small stand-ins for what the lab cannot have (a test CA, a mail sink, no GPU)
        lab = mk ./hosts/lab;
        # the lab host on UEFI with LUKS, the TPM and signed boot images: tried in a VM with an emulated TPM and Secure Boot (lab/tpm-u21.sh)
        lab-secure = mk ./hosts/lab-secure;
        # the same with the signed boot images on from the start: a rebuild that restored the signing keys from Borg before installing (lab/restore-drill.sh with DRILL_SECURE=1)
        # the lab host with the copy to Proton Drive switched on (lab/proton-offsite/): it needs the CLI's login, so it is not the plain lab host
        lab-offsite = (mk ./hosts/lab).extendModules { modules = [ { tidepool.offsite.proton.enable = true; } ]; };
        # the lab host with the names of the Incus instances on, and one instance public (lab/compute-names.sh)
        lab-compute = (mk ./hosts/lab).extendModules { modules = [ { tidepool.vms = { names.enable = true; public = [ "pub" ]; }; } ]; };
        lab-secure-sb = (mk ./hosts/lab-secure).extendModules { modules = [ { tidepool.encryption.secureBoot = true; } ]; };
        # the real host: the values that are private (domain, disks by serial, VPN peers) come from the private repository; this repository holds an example
        tidepool = mk ./hosts/tidepool;
      };
      # `nix flake check`: both hosts must build, on every change. The heavy proof (rebuild from blank and the restore) is lab/restore-drill.sh.
      checks.x86_64-linux = {
        lab = self.nixosConfigurations.lab.config.system.build.toplevel;
        tidepool = self.nixosConfigurations.tidepool.config.system.build.toplevel;
        # the version-watch rules (ADR 0017) against their unit test: 11 days of synthetic series, the alerts must fire on a weekend and only when a week is complete
        versions-rules = let pkgs = nixpkgs.legacyPackages.x86_64-linux; in pkgs.runCommand "versions-rules" { nativeBuildInputs = [ pkgs.prometheus.cli ]; } ''
          cp ${./modules/versions}/rules.yml ${./modules/versions}/rules.test.yml .
          promtool check rules rules.yml
          promtool test rules rules.test.yml
          touch $out
        '';
      };
    };
}
