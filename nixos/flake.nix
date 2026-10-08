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
        # the lab host on UEFI with LUKS, the TPM and signed boot images: tried in a VM with an emulated TPM and Secure Boot (lab/experiments/tpm-u21.sh)
        lab-secure = mk ./hosts/lab-secure;
        # the same with the signed boot images on from the start: a rebuild that restored the signing keys from Borg before installing (lab/restore-drill.sh with DRILL_SECURE=1)
        # the lab host with the copy to Proton Drive switched on (lab/proton-offsite/): it needs the CLI's login, so it is not the plain lab host
        lab-offsite = (mk ./hosts/lab).extendModules { modules = [ { tidepool.offsite.proton.enable = true; } ]; };
        # the lab host with the names of the Incus instances on, and one instance public (lab/compute-names.sh)
        lab-compute = (mk ./hosts/lab).extendModules { modules = [ { tidepool.compute = { names.enable = true; public = [ "pub" ]; }; } ]; };
        # the lab host with the brand on (lab/brand-test.sh)
        lab-brand = (mk ./hosts/lab).extendModules { modules = [ ({ lib, ... }: {
          tidepool.sso.enable = true;
          # Jellyfin is off in the lab host; here it runs, on an empty library, so that its branding can be looked at
          tidepool.services.jellyfin = { enable = lib.mkForce true; mediaMounts = lib.mkForce { "/media" = "/srv/data/media"; }; };
          systemd.tmpfiles.rules = [ "d /srv/data/media 0755 root root -" ];
        }) ]; };
        lab-secure-sb = (mk ./hosts/lab-secure).extendModules { modules = [ { tidepool.encryption.secureBoot = true; } ]; };
        # the real host: the values that are private (domain, disks by serial, VPN peers) come from the private repository; this repository holds an example
        tidepool = mk ./hosts/tidepool;
      };
      # the repository's face, made from the brand (nixos/brand/): `nix build .#brand-preview` gives the 1280x640 image for GitHub's social preview and the README; docs/brand/ holds the last one
      packages.x86_64-linux.brand-preview = let
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        b = self.nixosConfigurations.lab.config.tidepool.brand;
        fonts = pkgs.makeFontsConf { fontDirectories = [ pkgs.inter ]; };
      in pkgs.runCommand "brand-preview.png" { nativeBuildInputs = [ pkgs.librsvg pkgs.coreutils ]; FONTCONFIG_FILE = fonts; } ''
        logo=$(base64 -w0 ${b.logo})
        cat > preview.svg <<SVG
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="1280" height="640" viewBox="0 0 1280 640">
          <rect width="1280" height="640" fill="${b.colors.deep}"/>
          <rect y="600" width="1280" height="40" fill="${b.colors.primary}"/>
          <image x="140" y="190" width="260" height="260" xlink:href="data:image/svg+xml;base64,$logo"/>
          <text x="450" y="330" font-family="Inter" font-weight="700" font-size="120" fill="${b.colors.sand}">${b.name}</text>
          <text x="454" y="400" font-family="Inter" font-size="44" fill="${b.colors.primaryOnDark}">${b.tagline}</text>
        </svg>
        SVG
        rsvg-convert preview.svg -o $out
      '';
      # `nix flake check`: both hosts must build and the unit tests pass, on every change (nixos/checks.nix). What needs a running machine is lab/gate.sh, by hand before a push to main.
      checks.x86_64-linux = import ./checks.nix { inherit self nixpkgs; };
    };
}
